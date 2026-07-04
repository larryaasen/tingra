# Streaming Service Simulator

To test `tingra-cli` (and later the app) without touching Twitch or YouTube, the repo includes a local simulator: a real RTMP/SRT ingest server running on the developer's machine that is indistinguishable from a production service as far as the client is concerned. The client does a real handshake, real key validation, and pushes real encoded media.

## Decision: MediaMTX + a thin harness

Rather than writing an RTMP server, we adopt [MediaMTX](https://github.com/bluenviron/mediamtx) (MIT licensed, actively maintained) and wrap it in a small amount of config and scripting.

Why MediaMTX over the alternatives:

| Server | Notes |
| :----- | :---- |
| **MediaMTX** | Single static binary, zero dependencies, native macOS (Apple Silicon) build, supports RTMP **and** SRT ingest plus HLS/RTSP readback for verification, per path publish auth. Best fit. |
| SRS | Full featured but heavier; Docker oriented; more than we need. |
| node-media-server | RTMP only, requires Node runtime, spottier maintenance. |
| nginx-rtmp | RTMP only, requires building nginx with a module; the module is largely unmaintained. |

If MediaMTX ever becomes unsuitable, the harness scripts are the only thing that changes; the CLI just sees an RTMP/SRT endpoint.

## What "looks like a real service" means

The simulator reproduces the observable behavior of Twitch/YouTube ingest:

1. **URL shape.** Twitch style `rtmp://localhost:1935/live/{stream_key}` and YouTube style `rtmp://localhost:1935/live2/{stream_key}`, plus SRT at `srt://localhost:8890?streamid=publish:{path}`.
2. **Stream key validation.** Publishing with a wrong key is rejected at connect time, so the CLI's error and reconnect paths can be exercised deliberately.
3. **Real media handling.** The server demuxes the FLV/MPEG-TS payload; a corrupt stream fails visibly rather than being blindly accepted.
4. **Readback for verification.** Tests confirm the stream actually arrived (codec, resolution, fps) by reading it back over RTSP/HLS with `ffprobe`.

## Harness layout

The simulator is one of the runnable products under `apps/` (see "Repository structure" in ARCHITECTURE.md):

```
apps/ingest-simulator/
  mediamtx.yml       # server config: paths, ports, publish auth
  sim.sh             # start | stop | status | verify
  keys.env           # test stream keys (fake values, committed)
```

### Config sketch (mediamtx.yml)

```yaml
rtmpAddress: :1935
srtAddress: :8890
hlsAddress: :8888

paths:
  # Twitch shaped ingest; key validated via publish credentials
  "live/tingra_test_key": {}
  # YouTube shaped ingest
  "live2/tingra_test_key": {}
  # Any other path is rejected -> simulates a bad stream key
```

Defining only the known key paths means an incorrect key fails the publish, which is exactly the behavior we want to test against. If we later need dynamic keys, MediaMTX supports an HTTP auth hook.

### sim.sh

- `sim.sh start` — download/locate the pinned MediaMTX release for macOS arm64 (cached under `apps/ingest-simulator/.bin/`, gitignored), launch it with `mediamtx.yml`, wait for ports.
- `sim.sh verify [path]` — `ffprobe` the readback URL and print codec/resolution/fps; nonzero exit if no stream.
- `sim.sh stop` / `sim.sh status`.

The MediaMTX version is pinned in `sim.sh` so test behavior is reproducible.

## Test scenarios enabled

| Scenario | How |
| :------- | :-- |
| Happy path RTMP | `tingra-cli stream --url rtmp://localhost:1935/live --key tingra_test_key --video-generator bars --audio-generator tone --duration 30`, then `sim.sh verify`. |
| Happy path SRT | Same via `srt://localhost:8890?streamid=publish:live/tingra_test_key`. |
| Bad stream key | Publish with a wrong key; assert CLI exits 75 with a clear error. |
| Reconnect logic | `sim.sh stop` mid stream, restart; assert the CLI reconnects within its retry budget. |
| Encoding matrix | Loop resolutions/codecs/bitrates; `verify` asserts what arrived matches what was requested. |
| Recording parity | Stream with `--record`; compare recorded file properties against the received stream. (Applies once `--record` ships, roadmap step 5.) |

These run locally today and in CI later (MediaMTX also ships Linux binaries, and generators need no camera or TCC authorization).

## Out of scope

The simulator does not reproduce service side features beyond ingest: no transcoding ladder, no chat, no stream health dashboard, no OAuth. If Tingra later integrates the Twitch/YouTube APIs (for example fetching a user's stream key), those calls get mocked separately at the HTTP layer.
