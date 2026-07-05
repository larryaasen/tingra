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

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures scenario check(s) did not pass."
    exit 1
fi
echo "All integration scenarios passed."
