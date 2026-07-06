#!/bin/bash
#
# integration-test.sh — the streaming integration tests (see SIMULATOR.md,
# "Test scenarios enabled", and CLI.md "Testing").
#
# Runs tingra-cli with generators against the local ingest simulator and
# verifies the stream server side with ffprobe: the happy RTMP path, the
# bad-stream-key rejection (exit 75), probe, and reconnect across a server
# outage. Generators mean no camera, no microphone, and no TCC
# authorization — these run on any machine and in the integration CI job
# (integration.yml), which triggers on streaming/output changes rather
# than blocking every PR.
#
# SRT scenarios join when SRT output lands (roadmap step 8).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$REPO_DIR/apps/ingest-simulator/sim.sh"
CLI_DIR="$REPO_DIR/apps/tingra-cli"
OUT_DIR="$(mktemp -d)"

RTMP_URL="rtmp://localhost:1935/live"
GOOD_KEY="tingra_test_key"
BAD_KEY="wrong_key"

# Everything the CLI needs beyond the destination: generators only.
GENERATOR_FLAGS=(--video-generator bars --audio-generator tone --resolution 640x360)

failures=0

# Reports one scenario result.
report() {
    local name="$1" ok="$2"
    if [[ "$ok" == "true" ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        failures=$((failures + 1))
    fi
}

cleanup() {
    "$SIM" stop > /dev/null 2>&1 || true
    rm -rf "$OUT_DIR"
}
trap cleanup EXIT

echo "== Building tingra-cli"
(cd "$CLI_DIR" && swift build)
CLI="$(cd "$CLI_DIR" && swift build --show-bin-path)/tingra-cli"

echo "== Starting the ingest simulator"
"$SIM" start

echo "== Scenario: happy path RTMP (bars + tone, verified server side)"
"$CLI" stream --url "$RTMP_URL" --key "$GOOD_KEY" "${GENERATOR_FLAGS[@]}" \
    --duration 20 --stats-interval 5 --json > "$OUT_DIR/happy.json" &
stream_pid=$!
sleep 8
verify_output="$("$SIM" verify "live/$GOOD_KEY")"
echo "$verify_output"
verify_ok=false
if grep -q "codec_name=h264" <<< "$verify_output" && grep -q "codec_name=aac" <<< "$verify_output"; then
    verify_ok=true
fi
report "server receives H.264 + AAC" "$verify_ok"

stream_ok=false
if wait "$stream_pid"; then
    stream_ok=true
fi
report "stream exits 0 after --duration" "$stream_ok"

events_ok=false
if grep -q '"name":"stream.started"' "$OUT_DIR/happy.json" \
    && grep -q '"name":"stream.stats"' "$OUT_DIR/happy.json" \
    && grep -q '"reason":"durationElapsed"' "$OUT_DIR/happy.json"; then
    events_ok=true
fi
report "started/stats/stopped events on the NDJSON stream" "$events_ok"

key_ok=true
if grep -q "$GOOD_KEY" "$OUT_DIR/happy.json"; then
    key_ok=false
fi
report "the stream key never appears in output" "$key_ok"

echo "== Scenario: bad stream key is rejected (exit 75)"
badkey_ok=false
if "$CLI" stream --url "$RTMP_URL" --key "$BAD_KEY" "${GENERATOR_FLAGS[@]}" \
    --duration 60 --reconnect 2 --reconnect-delay 1 --stats-interval 0 \
    --json > "$OUT_DIR/badkey.json" 2>&1; then
    badkey_ok=false
else
    if [[ $? -eq 75 ]]; then
        badkey_ok=true
    fi
fi
report "bad key exits 75 (connectionLost)" "$badkey_ok"

echo "== Scenario: probe"
probe_ok=false
if "$CLI" probe --url "$RTMP_URL" --key "$GOOD_KEY" > /dev/null; then
    probe_ok=true
fi
report "probe accepts the simulator destination" "$probe_ok"

probe_down_ok=false
if "$CLI" probe --url "rtmp://localhost:59999/live" --key "$GOOD_KEY" > /dev/null 2>&1; then
    probe_down_ok=false
else
    if [[ $? -eq 75 ]]; then
        probe_down_ok=true
    fi
fi
report "probe of an unreachable destination exits 75" "$probe_down_ok"

echo "== Scenario: reconnect across a server outage"
"$CLI" stream --url "$RTMP_URL" --key "$GOOD_KEY" "${GENERATOR_FLAGS[@]}" \
    --duration 35 --reconnect 5 --reconnect-delay 2 --stats-interval 0 \
    --json > "$OUT_DIR/reconnect.json" &
stream_pid=$!
sleep 8
"$SIM" stop
sleep 3
"$SIM" start
sleep 10
verify_after_ok=false
if "$SIM" verify "live/$GOOD_KEY" | grep -q "codec_name=h264"; then
    verify_after_ok=true
fi
report "the stream is publishing again after the outage" "$verify_after_ok"

reconnect_exit_ok=false
if wait "$stream_pid"; then
    reconnect_exit_ok=true
fi
report "stream survives the outage and exits 0" "$reconnect_exit_ok"

reconnect_events_ok=false
if grep -q '"name":"stream.reconnecting"' "$OUT_DIR/reconnect.json" \
    && grep -q '"name":"stream.reconnected"' "$OUT_DIR/reconnect.json"; then
    reconnect_events_ok=true
fi
report "reconnecting/reconnected events were emitted" "$reconnect_events_ok"

echo "== Scenario: MCP daemon stream lifecycle (serve + socket client, verified server side)"
# Start the daemon on a private socket (idle-exit disabled for the test), then
# drive it over the real socket with a minimal MCP client: initialize,
# tools/list, devices_list, then the stream lifecycle (start/status/stop)
# against the simulator with generators. This mirrors how an agent uses the
# engine (MCP.md), end to end.
MCP_SOCK="$OUT_DIR/tingra.sock"
"$CLI" serve --socket "$MCP_SOCK" --idle-timeout 0 --json > "$OUT_DIR/serve.json" 2>&1 &
serve_pid=$!
for _ in $(seq 1 50); do [[ -S "$MCP_SOCK" ]] && break; sleep 0.1; done

python3 - "$MCP_SOCK" "$RTMP_URL" "$GOOD_KEY" > "$OUT_DIR/mcp.out" 2>&1 <<'PY' &
import json, socket, sys, time

sock_path, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
conn.connect(sock_path)
stream = conn.makefile("rwb")
next_id = [0]

def call(method, params=None):
    next_id[0] += 1
    request = {"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params or {}}
    stream.write((json.dumps(request) + "\n").encode())
    stream.flush()
    while True:  # Skip status notifications (no matching id) until the response.
        line = stream.readline()
        if not line:
            raise SystemExit("connection closed before a response")
        message = json.loads(line.decode())
        if message.get("id") == next_id[0]:
            return message

assert call("initialize")["result"]["serverInfo"]["name"] == "tingra"
tools = [t["name"] for t in call("tools/list")["result"]["tools"]]
assert "stream_start" in tools, tools
assert call("tools/call", {"name": "devices_list"})["result"]["isError"] is False

start = call("tools/call", {"name": "stream_start", "arguments": {
    "url": url, "key": key, "videoGenerator": "bars", "audioGenerator": "tone",
    "resolution": "640x360", "statsInterval": 2,
}})
assert start["result"]["isError"] is False, start
session_id = start["result"]["structuredContent"]["sessionId"]
print("STARTED", session_id, flush=True)

time.sleep(9)
status = call("tools/call", {"name": "stream_status", "arguments": {"sessionId": session_id}})
print("STATUS", json.dumps(status["result"]["structuredContent"]), flush=True)
assert call("tools/call", {"name": "stream_stop", "arguments": {"sessionId": session_id}})["result"]["isError"] is False
print("STOPPED", flush=True)
conn.close()
PY
client_pid=$!

# While the MCP-driven stream runs, verify the media server side.
sleep 5
mcp_verify_ok=false
if "$SIM" verify "live/$GOOD_KEY" | grep -q "codec_name=h264"; then
    mcp_verify_ok=true
fi
report "MCP stream_start publishes H.264 to the simulator" "$mcp_verify_ok"

client_ok=false
if wait "$client_pid"; then
    client_ok=true
fi
report "MCP client round-trips initialize/devices_list/start/status/stop" "$client_ok"

mcp_flow_ok=false
if grep -q '^STARTED ' "$OUT_DIR/mcp.out" \
    && grep -q '"state": "live"' "$OUT_DIR/mcp.out" \
    && grep -q '^STOPPED' "$OUT_DIR/mcp.out"; then
    mcp_flow_ok=true
fi
report "MCP lifecycle markers (started/live/stopped) observed" "$mcp_flow_ok"

kill -INT "$serve_pid" 2> /dev/null || true
shutdown_ok=false
if wait "$serve_pid"; then
    shutdown_ok=true
fi
report "the daemon shuts down cleanly (exit 0)" "$shutdown_ok"

mcp_key_ok=true
if grep -q "$GOOD_KEY" "$OUT_DIR/serve.json"; then
    mcp_key_ok=false
fi
report "the stream key never appears in the daemon log" "$mcp_key_ok"

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures scenario check(s) did not pass."
    exit 1
fi
echo "All integration scenarios passed."
