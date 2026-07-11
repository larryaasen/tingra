# Makefile — a reference guide of tingra-cli commands (see ../../docs/CLI.md).
# Every target is a copy-pasteable example exercising one feature; run
# `make help` to list them all with their one-line descriptions.
#
# Streaming and probe targets need the local ingest simulator running:
#   make sim-start
# and stopped when you're done:
#   make sim-stop

.DEFAULT_GOAL := help

SIM := ../ingest-simulator/sim.sh
RTMP_URL := rtmp://localhost:1935/live
TWITCH_URL := rtmp://live.twitch.tv/app
GOOD_KEY := tingra_test_key
BAD_KEY := wrong_key
GENERATORS := --video-generator alignment --audio-generator tone

.PHONY: help build test clean format check-format version \
	devices devices-json devices-camera devices-mic devices-watch \
	sim-start sim-stop sim-status sim-verify \
	stream stream-twitch stream-json stream-dry-run stream-no-video stream-no-audio \
	stream-camera stream-bad-key stream-reconnect \
	probe probe-bad-key probe-down \
	integration-test

help: ## List every target with its one-line description
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# MARK: - Build and test

build: ## Build tingra-cli in debug configuration
	swift build

test: ## Run the unit test suite
	swift test

clean: ## Remove build artifacts
	swift package clean

format: ## Format every Swift file in the monorepo
	../../scripts/format-swift.sh

check-format: ## Verify formatting without changing files (the CI check)
	../../scripts/check-format.sh

# MARK: - Version

version: ## Print version and build info
	swift run tingra-cli version

# MARK: - Devices

devices: ## List cameras/mics as a human table
	swift run tingra-cli devices

devices-json: ## Same, as stable JSON for scripting
	swift run tingra-cli devices --json

devices-camera: ## Filter the listing to cameras only
	swift run tingra-cli devices --type camera

devices-mic: ## Filter the listing to microphones only
	swift run tingra-cli devices --type mic

devices-watch: ## Stay open, printing device connect/disconnect events live
	swift run tingra-cli devices --watch

# MARK: - Local ingest simulator (needed for every stream/probe target below)

sim-start: ## Start the local ingest simulator (RTMP :1935, RTSP :8554)
	$(SIM) start

sim-stop: ## Stop the local ingest simulator
	$(SIM) stop

sim-status: ## Report whether the simulator is running
	$(SIM) status

sim-verify: ## ffprobe the simulator's RTSP readback; prints codec/resolution/fps
	$(SIM) verify live/$(GOOD_KEY)

# MARK: - Stream (generators; run `make sim-start` first)

stream: ## Stream generated bars + tone to the simulator for 15s
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) $(GENERATORS) --duration 15 --verbose

stream-twitch: ## Stream generated bars + tone to Twitch (set TWITCH_KEY in env)
	@test -n "$(TWITCH_KEY)" || (echo "Set TWITCH_KEY to your Twitch stream key."; exit 2)
	swift run tingra-cli stream --url $(TWITCH_URL) --key $(TWITCH_KEY) $(GENERATORS) --verbose

stream-json: ## Same, emitting NDJSON status events instead of human logs
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) $(GENERATORS) --duration 15 --json

stream-dry-run: ## Resolve inputs and print the plan without connecting
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) --dry-run

stream-no-video: ## Audio-only stream (tone generator)
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) --no-video --audio-generator tone --duration 15

stream-no-audio: ## Video-only stream (bars generator)
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) --no-audio --video-generator bars --duration 15

stream-camera: ## Stream the system default camera + microphone (needs TCC authorization)
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) --duration 15

stream-camera-twitch: ## Stream the system default camera + microphone (needs TCC authorization) to Twitch (set TWITCH_KEY in env)
	@test -n "$(TWITCH_KEY)" || (echo "Set TWITCH_KEY to your Twitch stream key."; exit 2)
	swift run tingra-cli stream --url $(TWITCH_URL) --key $(TWITCH_KEY) --duration 15 --verbose

stream-bad-key: ## Wrong stream key: reconnects on the policy, then exits 75
	swift run tingra-cli stream --url $(RTMP_URL) --key $(BAD_KEY) $(GENERATORS) --duration 30 --reconnect 2 --reconnect-delay 1

stream-reconnect: ## Long-running stream to test reconnect — stop/start the sim while it runs
	swift run tingra-cli stream --url $(RTMP_URL) --key $(GOOD_KEY) $(GENERATORS) --duration 60 --reconnect 5 --reconnect-delay 2

# MARK: - Probe

probe: ## Handshake + disconnect against the simulator, no media sent
	swift run tingra-cli probe --url $(RTMP_URL) --key $(GOOD_KEY)

probe-bad-key: ## Wrong stream key: exits 75
	swift run tingra-cli probe --url $(RTMP_URL) --key $(BAD_KEY)

probe-down: ## Unreachable destination: exits 75
	swift run tingra-cli probe --url rtmp://localhost:59999/live --key $(GOOD_KEY)

# MARK: - Integration

integration-test: ## Run the full streaming integration suite against the simulator
	../../scripts/integration-test.sh
