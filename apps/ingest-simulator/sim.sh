#!/bin/bash
#
# sim.sh — the local ingest simulator harness (see docs/SIMULATOR.md).
#
# Wraps MediaMTX (MIT licensed) in a thin start/stop/status/verify script so
# tingra-cli and the integration tests can exercise a real RTMP/SRT ingest
# server without touching Twitch or YouTube. Test-only; never linked into
# the product.
#
#   sim.sh start          Download/locate the pinned MediaMTX, launch it
#                         with mediamtx.yml, wait for the ingest ports, and
#                         print the destination URL and key to publish with.
#   sim.sh stop           Stop the running server.
#   sim.sh status         Report whether the server is running, and reprint
#                         the destination URL and key.
#   sim.sh verify [path]  ffprobe the RTSP readback of a path (default
#                         live/tingra_test_key) and print codec, resolution,
#                         and fps; nonzero exit if no stream is there.

set -euo pipefail

# The pinned MediaMTX release, so test behavior is reproducible.
MEDIAMTX_VERSION="v1.19.2"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$BASE_DIR/.bin"
BINARY="$BIN_DIR/mediamtx-$MEDIAMTX_VERSION"
CONFIG="$BASE_DIR/mediamtx.yml"
KEYS_FILE="$BASE_DIR/keys.env"
PID_FILE="$BIN_DIR/mediamtx.pid"
LOG_FILE="$BIN_DIR/mediamtx.log"

RTMP_PORT=1935
RTSP_PORT=8554
SRT_PORT=8890

# Prints the MediaMTX release asset name for this machine (macOS arm64 for
# development; Linux for CI runners).
asset_name() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux) os="linux" ;;
        *)
            echo "error: unsupported OS $(uname -s)" >&2
            exit 1
            ;;
    esac
    case "$(uname -m)" in
        arm64 | aarch64) arch="arm64" ;;
        x86_64) arch="amd64" ;;
        *)
            echo "error: unsupported architecture $(uname -m)" >&2
            exit 1
            ;;
    esac
    echo "mediamtx_${MEDIAMTX_VERSION}_${os}_${arch}.tar.gz"
}

# Downloads the pinned MediaMTX release into the cache if it is not already
# there (the cache is gitignored).
fetch_binary() {
    if [[ -x "$BINARY" ]]; then
        return
    fi
    local asset url tmp
    asset="$(asset_name)"
    url="https://github.com/bluenviron/mediamtx/releases/download/$MEDIAMTX_VERSION/$asset"
    echo "sim: downloading MediaMTX $MEDIAMTX_VERSION ($asset)…"
    mkdir -p "$BIN_DIR"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/$asset" "$url"
    tar -xzf "$tmp/$asset" -C "$tmp" mediamtx
    mv "$tmp/mediamtx" "$BINARY"
    rm -rf "$tmp"
    chmod +x "$BINARY"
}

# Prints the PID of the running server, if any.
running_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE")"
        if kill -0 "$pid" 2> /dev/null; then
            echo "$pid"
        fi
    fi
}

# Prints the valid test key, read from keys.env — the one place it is
# defined, so this script can never name a key the paths in mediamtx.yml do
# not accept. Prints nothing if the file is missing or defines no key.
test_key() {
    if [[ -r "$KEYS_FILE" ]]; then
        (
            # shellcheck source=keys.env
            . "$KEYS_FILE"
            echo "${TINGRA_TEST_KEY:-}"
        )
    fi
}

# Prints the destination URL and stream key to publish with.
#
# The app's streaming panel takes the URL and the key as two separate
# fields, and so does `tingra-cli stream` (--url/--key), so a single
# concatenated rtmp://host/app/key string is exactly what neither can use —
# printing the pair is the whole point of this block.
destinations() {
    # Only when a person is watching: the integration tests call `start` and
    # `status` repeatedly, and a paste-ready block in the middle of their
    # output is noise nobody reads.
    if [[ ! -t 1 ]]; then
        return
    fi
    local key
    key="$(test_key)"
    if [[ -z "$key" ]]; then
        echo "sim: warning: no TINGRA_TEST_KEY in $KEYS_FILE; see docs/SIMULATOR.md" >&2
        return
    fi
    cat << EOF

  Publish to it — URL and key are separate fields in the app's streaming panel:

    RTMP   URL  rtmp://localhost:$RTMP_PORT/live
           Key  $key

    SRT    URL  srt://localhost:$SRT_PORT
           Key  publish:live/$key

  The same pair as CLI options:
    --url rtmp://localhost:$RTMP_PORT/live --key $key

  Then check it arrived: sim.sh verify
EOF
}

start() {
    if [[ -n "$(running_pid)" ]]; then
        echo "sim: already running (pid $(running_pid))"
        destinations
        return
    fi
    fetch_binary
    "$BINARY" "$CONFIG" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    # Wait for the ingest and readback listeners to open.
    local i
    for i in $(seq 1 50); do
        if nc -z localhost "$RTMP_PORT" 2> /dev/null && nc -z localhost "$RTSP_PORT" 2> /dev/null; then
            echo "sim: running (pid $(cat "$PID_FILE")) — RTMP :$RTMP_PORT, SRT :$SRT_PORT, RTSP :$RTSP_PORT, HLS :8888"
            destinations
            return
        fi
        sleep 0.2
    done
    echo "error: MediaMTX did not open its ports; see $LOG_FILE" >&2
    exit 1
}

stop() {
    local pid
    pid="$(running_pid)"
    if [[ -z "$pid" ]]; then
        echo "sim: not running"
        rm -f "$PID_FILE"
        return
    fi
    kill "$pid"
    rm -f "$PID_FILE"
    echo "sim: stopped"
}

status() {
    local pid
    pid="$(running_pid)"
    if [[ -n "$pid" ]]; then
        echo "sim: running (pid $pid)"
        destinations
    else
        echo "sim: not running"
        exit 1
    fi
}

# Reads the stream back over RTSP with ffprobe and prints codec, resolution,
# and fps per stream; nonzero exit if nothing is publishing to the path.
verify() {
    local path="${1:-live/tingra_test_key}"
    if ! command -v ffprobe > /dev/null; then
        echo "error: ffprobe is required for verify (brew install ffmpeg)" >&2
        exit 1
    fi
    ffprobe -v error -rtsp_transport tcp \
        -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,sample_rate,channels \
        -of default=noprint_wrappers=1 \
        "rtsp://localhost:$RTSP_PORT/$path"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    verify) verify "${2:-}" ;;
    *)
        echo "usage: sim.sh start | stop | status | verify [path]" >&2
        exit 64
        ;;
esac
