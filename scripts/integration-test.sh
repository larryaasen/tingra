#!/bin/bash
#
# integration-test.sh — the streaming integration tests (see SIMULATOR.md,
# "Test scenarios enabled", and CLI.md "Testing").
#
# Runs tingra-cli with generators against the local ingest simulator and
# verifies the stream server side with ffprobe: the happy RTMP and SRT
# paths, multiple destinations (one program fanned out to two paths, both
# read back) and a partial start rejection, the bad-stream-key rejection
# (exit 75) for both transports, probe, and reconnect across a server
# outage. Generators mean no camera, no
# microphone, and no TCC authorization — these run on any machine and in the
# integration CI job (integration.yml), which triggers on streaming/output
# changes rather than blocking every PR.
#
# The SRT scenarios (roadmap step 8) exercise the --key → streamid
# composition end to end: the key is passed as the whole MediaMTX streamid
# and the SRT service composes it into the connect URL.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$REPO_DIR/apps/ingest-simulator/sim.sh"
CLI_DIR="$REPO_DIR/apps/tingra-cli"
OUT_DIR="$(mktemp -d)"

RTMP_URL="rtmp://localhost:1935/live"
# The second configured path, so the fan-out scenario streams one program to
# a Twitch-shaped and a YouTube-shaped destination at once and reads back both.
RTMP2_URL="rtmp://localhost:1935/live2"
SRT_URL="srt://localhost:8890"
# A port nothing listens on, for the destination that must be refused at
# connect time (the same address the probe scenario uses).
UNREACHABLE_URL="rtmp://localhost:59999/live"
GOOD_KEY="tingra_test_key"
BAD_KEY="wrong_key"
# SRT carries the publish target in the streamid; MediaMTX's shape is
# `publish:<path>` (SIMULATOR.md). The whole streamid is passed as the key so
# the SRT service composes it into the URL (CLI.md, "Destination").
SRT_GOOD_KEY="publish:live/$GOOD_KEY"
SRT_BAD_KEY="publish:live/$BAD_KEY"

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

echo "== Scenario: happy path SRT (bars + tone, key composed into streamid, verified server side)"
# The key is passed as the whole MediaMTX streamid; the SRT service composes
# it into srt://localhost:8890?streamid=publish:live/tingra_test_key, which
# MediaMTX routes to the live/tingra_test_key path — read back the same way.
"$CLI" stream --url "$SRT_URL" --key "$SRT_GOOD_KEY" "${GENERATOR_FLAGS[@]}" \
    --duration 20 --stats-interval 5 --json > "$OUT_DIR/srt.json" &
srt_pid=$!
sleep 8
srt_verify_output="$("$SIM" verify "live/$GOOD_KEY")"
echo "$srt_verify_output"
srt_verify_ok=false
if grep -q "codec_name=h264" <<< "$srt_verify_output" && grep -q "codec_name=aac" <<< "$srt_verify_output"; then
    srt_verify_ok=true
fi
report "SRT server receives H.264 + AAC" "$srt_verify_ok"

srt_stream_ok=false
if wait "$srt_pid"; then
    srt_stream_ok=true
fi
report "SRT stream exits 0 after --duration" "$srt_stream_ok"

srt_events_ok=false
if grep -q '"name":"stream.started"' "$OUT_DIR/srt.json" \
    && grep -q '"name":"stream.stats"' "$OUT_DIR/srt.json" \
    && grep -q '"reason":"durationElapsed"' "$OUT_DIR/srt.json"; then
    srt_events_ok=true
fi
report "SRT started/stats/stopped events on the NDJSON stream" "$srt_events_ok"

srt_key_ok=true
if grep -q "$GOOD_KEY" "$OUT_DIR/srt.json"; then
    srt_key_ok=false
fi
report "the SRT stream key never appears in output" "$srt_key_ok"

echo "== Scenario: multiple destinations (one program fanned out to two RTMP paths, both verified)"
# The real shape of the feature: one program to a Twitch-style path and a
# YouTube-style path at once, keys paired with --url by position. Both are
# read back independently, so this proves the fan-out delivers to each rather
# than one leg quietly winning (ARCHITECTURE.md, "Multiple destinations").
"$CLI" stream --url "$RTMP_URL" --key "$GOOD_KEY" --url "$RTMP2_URL" --key "$GOOD_KEY" \
    "${GENERATOR_FLAGS[@]}" --duration 20 --stats-interval 5 --json > "$OUT_DIR/fanout.json" &
fanout_pid=$!
sleep 8
fanout_first="$("$SIM" verify "live/$GOOD_KEY")"
fanout_second="$("$SIM" verify "live2/$GOOD_KEY")"
echo "$fanout_first"
echo "$fanout_second"
fanout_verify_ok=false
if grep -q "codec_name=h264" <<< "$fanout_first" && grep -q "codec_name=aac" <<< "$fanout_first" \
    && grep -q "codec_name=h264" <<< "$fanout_second" && grep -q "codec_name=aac" <<< "$fanout_second"; then
    fanout_verify_ok=true
fi
report "both destinations receive H.264 + AAC" "$fanout_verify_ok"

fanout_stream_ok=false
if wait "$fanout_pid"; then
    fanout_stream_ok=true
fi
report "the fanned-out stream exits 0 after --duration" "$fanout_stream_ok"

# Each leg announces itself and reports its own stats under its own id.
fanout_events_ok=false
if grep -q '"destination":"destination-1"' "$OUT_DIR/fanout.json" \
    && grep -q '"destination":"destination-2"' "$OUT_DIR/fanout.json" \
    && grep -q '"name":"stream.destination.started"' "$OUT_DIR/fanout.json" \
    && grep -q '"destinations":2' "$OUT_DIR/fanout.json"; then
    fanout_events_ok=true
fi
report "per-destination started events and a destination count of 2" "$fanout_events_ok"

fanout_stats_ok=false
if grep '"name":"stream.stats"' "$OUT_DIR/fanout.json" | grep -q '"destination":"destination-1"' \
    && grep '"name":"stream.stats"' "$OUT_DIR/fanout.json" | grep -q '"destination":"destination-2"'; then
    fanout_stats_ok=true
fi
report "both destinations report their own stats" "$fanout_stats_ok"

fanout_key_ok=true
if grep -q "$GOOD_KEY" "$OUT_DIR/fanout.json"; then
    fanout_key_ok=false
fi
report "no stream key appears in the fanned-out output" "$fanout_key_ok"

echo "== Scenario: one destination rejected at start, the run continues on the other (exit 0)"
# Best-effort start (CLI.md, "Multiple destinations"): the unreachable
# destination is refused and reported as connectionFailed, the good one goes
# live, and the run still exits 0 because a live leg remains. An unreachable
# port is used because MediaMTX does not refuse a bad key at connect — it
# accepts and closes, which is the mid-stream case exercised below.
"$CLI" stream --url "$RTMP_URL" --key "$GOOD_KEY" --url "$UNREACHABLE_URL" --key "$GOOD_KEY" \
    "${GENERATOR_FLAGS[@]}" --duration 15 --stats-interval 5 --json > "$OUT_DIR/partial.json" &
partial_pid=$!
sleep 6
partial_verify="$("$SIM" verify "live/$GOOD_KEY")"
echo "$partial_verify"
partial_verify_ok=false
if grep -q "codec_name=h264" <<< "$partial_verify"; then
    partial_verify_ok=true
fi
report "the accepted destination still receives the program" "$partial_verify_ok"

partial_exit_ok=false
if wait "$partial_pid"; then
    partial_exit_ok=true
fi
report "a partial start rejection still exits 0" "$partial_exit_ok"

partial_events_ok=false
if grep -q '"name":"stream.destination.rejected"' "$OUT_DIR/partial.json" \
    && grep -q '"identifier":"connectionFailed"' "$OUT_DIR/partial.json" \
    && grep -q '"destinations":1' "$OUT_DIR/partial.json" \
    && grep -q '"destinationsRejected":1' "$OUT_DIR/partial.json" \
    && grep -q '"reason":"durationElapsed"' "$OUT_DIR/partial.json"; then
    partial_events_ok=true
fi
report "the refused destination is reported without ending the run" "$partial_events_ok"

echo "== Scenario: one destination's outage does not disturb the other (per-leg reconnect)"
# The crux of per-leg state. A bad key is accepted then closed by MediaMTX —
# the rejected-stream-key shape — so that leg reconnects on its own budget
# while the good leg streams straight through, untouched and never charged
# for the other's outage.
"$CLI" stream --url "$RTMP_URL" --key "$GOOD_KEY" --url "$RTMP_URL" --key "$BAD_KEY" \
    "${GENERATOR_FLAGS[@]}" --duration 15 --stats-interval 5 --json > "$OUT_DIR/perleg.json" &
perleg_pid=$!

perleg_exit_ok=false
if wait "$perleg_pid"; then
    perleg_exit_ok=true
fi
report "one destination flapping still exits 0" "$perleg_exit_ok"

# Every reconnect belongs to the failing leg; the healthy one has none.
perleg_isolated_ok=false
if grep '"name":"stream.reconnecting"' "$OUT_DIR/perleg.json" | grep -q '"destination":"destination-2"' \
    && ! grep '"name":"stream.reconnecting"' "$OUT_DIR/perleg.json" | grep -q '"destination":"destination-1"'; then
    perleg_isolated_ok=true
fi
report "only the failing destination reconnects" "$perleg_isolated_ok"

perleg_healthy_ok=false
if grep '"name":"stream.stats"' "$OUT_DIR/perleg.json" | grep -q '"destination":"destination-1"' \
    && grep -q '"reason":"durationElapsed"' "$OUT_DIR/perleg.json"; then
    perleg_healthy_ok=true
fi
report "the healthy destination keeps reporting throughout" "$perleg_healthy_ok"

echo "== Scenario: local recording (--record) alongside streaming, verified with ffprobe"
# Record the same program that streams: bars + tone to a temp .mp4 while
# publishing to the simulator, then verify the finalized file with ffprobe.
REC_FILE="$OUT_DIR/recording.mp4"
"$CLI" stream --url "$RTMP_URL" --key "$GOOD_KEY" "${GENERATOR_FLAGS[@]}" \
    --record "$REC_FILE" --duration 12 --stats-interval 0 --json > "$OUT_DIR/record.json" 2>&1
record_exit=$?

record_exit_ok=false
[[ $record_exit -eq 0 ]] && record_exit_ok=true
report "recording stream exits 0 after --duration" "$record_exit_ok"

record_events_ok=false
if grep -q '"name":"recording.started"' "$OUT_DIR/record.json" \
    && grep -q '"name":"recording.stopped"' "$OUT_DIR/record.json"; then
    record_events_ok=true
fi
report "recording.started/recording.stopped events on the NDJSON stream" "$record_events_ok"

record_file_ok=false
[[ -s "$REC_FILE" ]] && record_file_ok=true
report "the recording file exists and is non-empty" "$record_file_ok"

record_codecs="$(ffprobe -v error -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$REC_FILE" 2>/dev/null || true)"
record_codec_ok=false
if grep -q '^h264$' <<< "$record_codecs" && grep -q '^aac$' <<< "$record_codecs"; then
    record_codec_ok=true
fi
report "the recording contains an H.264 video track and an AAC audio track" "$record_codec_ok"

record_duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$REC_FILE" 2>/dev/null || echo 0)"
record_duration_ok=false
# The 12-second recording should land within a couple of seconds either way.
if awk -v d="$record_duration" 'BEGIN { exit !(d >= 9 && d <= 15) }'; then
    record_duration_ok=true
fi
report "the recording duration is approximately 12 seconds (got ${record_duration}s)" "$record_duration_ok"

record_key_ok=true
if grep -q "$GOOD_KEY" "$OUT_DIR/record.json"; then
    record_key_ok=false
fi
report "the stream key never appears in the recording run output" "$record_key_ok"

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

echo "== Scenario: bad SRT stream key is rejected (exit 75)"
# A streamid whose path MediaMTX does not define is rejected at the SRT
# handshake — the connectionFailed path for SRT, mirroring RTMP.
srt_badkey_ok=false
if "$CLI" stream --url "$SRT_URL" --key "$SRT_BAD_KEY" "${GENERATOR_FLAGS[@]}" \
    --duration 60 --reconnect 2 --reconnect-delay 1 --stats-interval 0 \
    --json > "$OUT_DIR/srt-badkey.json" 2>&1; then
    srt_badkey_ok=false
else
    if [[ $? -eq 75 ]]; then
        srt_badkey_ok=true
    fi
fi
report "bad SRT key exits 75 (connectionLost)" "$srt_badkey_ok"

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
