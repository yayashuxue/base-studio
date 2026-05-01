# Base Studio

Mac screen-recording + editor in the spirit of Screen Studio. Architecture-first;
see [`PRD.md`](PRD.md) and [`TECH_DESIGN.md`](TECH_DESIGN.md).

## Status: M0 — recording + raw playback

What works:

- Screen capture via ScreenCaptureKit, written to H.264 `.mov` (cursor **not** burned in).
- Cursor + click sidecar (`cursor.json`) sampled at 120 Hz on the **same host clock**
  as video PTSes (PRD §6).
- Per-recording project bundle on disk: `<name>.basestudio/{screen.mov, cursor.json, metadata.json}`.
- Dumb AVPlayer-based playback in-app.

What's *not* here yet (and intentionally so):

- No EDL, no scrubber, no effects, no audio. Those land in M1–M5 per PRD §10.
- No compositor — playback uses AVPlayer directly. The compositor-backed player
  arrives at M2 alongside the export pipeline, sharing the same renderer (PRD §5a).

## Build & run

```bash
swift build
swift run BaseStudio
```

The first time you Record, macOS will prompt for **Screen Recording** and
**Input Monitoring** permissions (the latter for the global click monitor).
Recordings land in `~/Movies/BaseStudio/`.

## Test

```bash
swift test
```

The serious test suite (preview/export parity, A/V drift, long-timeline memory)
arrives in M1–M2 — those tests need an EDL and a renderer to exercise.

## Layout

```
Sources/
├── BaseStudioCore/         — Time, ProjectBundle (no AVFoundation deps)
├── BaseStudioRecording/    — ScreenRecorder, CursorRecorder, RecordingSession
├── BaseStudioPlayback/     — RawPlayer (M0); becomes EngineBackedPlayer in M2
└── BaseStudioApp/          — SwiftUI shell
```
