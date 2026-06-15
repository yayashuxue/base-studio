# Base Studio

A macOS screen recorder + editor in the spirit of [Screen Studio](https://screen.studio).
Record your screen, your camera, and your microphone — get a polished, animated
video with auto-zoom on clicks, smooth cursor trails, padded backgrounds, and
crisp captions, without ever opening a separate editor.

> **Architecture-first.** The category is full of apps that ship a great demo
> and break the moment a timeline gets long, a speed ramp gets aggressive, or a
> webcam track desyncs. This codebase is structured to make those failure modes
> impossible by construction. The full thesis lives in
> [`PRD.md`](PRD.md) and [`TECH_DESIGN.md`](TECH_DESIGN.md) — start there if
> you're poking around.

---

## What works today

**Capture**
- Screen via `ScreenCaptureKit` (cursor *not* burned in — kept as a sidecar).
- Webcam via `AVCaptureSession`, recorded to its own `webcam.mov` so the editor
  can place / scale it independently.
- Mic via `AVCaptureSession`, recorded to `mic.m4a`.
- Cursor positions + click events sampled at 120 Hz on the **same host clock**
  as video PTSes (PRD §6).

**Edit**
- Edit Decision List (EDL) is the single source of truth — source files are
  immutable.
- Auto-zoom on every click via piecewise time-mapped zoom regions.
- Cursor halo + click bubble overlays driven by the cursor sidecar.
- Background gradients (5 curated presets) **or** any uploaded wallpaper image.
- Inline captions, scrubber, trim handles.
- Pitch-preserving speed ramps (`AVAudioUnitTimePitch`) — fast / slow regions
  re-time both video frames and audio without drift, sharing one `f(t)`.

**Export**
- Single offline pipeline (`ExportPipeline`) that shares the renderer with the
  preview — preview/export parity is enforced by code path, not testing.
- Mixes screen audio + mic into one AAC track. Time-mapped through the same
  `TimeMap` as video, so sync survives speed ramps.
- Headless e2e test (`BaseStudioRenderTests/ExportPipelineE2ETests.swift`)
  guards the audio file-time contract.

---

## Build & run

The shortest path on a Mac with Xcode 15+ installed:

```bash
git clone https://github.com/yayashuxue/base-studio.git
cd base-studio
./scripts/build-app.sh           # builds + signs build/Base Studio.app
open "build/Base Studio.app"
```

`build-app.sh` will pick the strongest signing identity it finds:

1. Apple Developer cert (`Apple Development:` / `Apple Distribution:`) — TCC
   permissions persist across rebuilds. Recommended.
2. A self-signed `Base Studio Dev` cert — run `./scripts/setup-dev-cert.sh`
   once to create it.
3. Ad-hoc — works, but macOS re-prompts for camera / screen / mic on every
   rebuild. Fine for a quick try.

The first run will prompt for **Screen Recording**, **Camera**, **Microphone**,
and **Input Monitoring** (for the global click monitor). Recordings live at
`~/Library/Application Support/BaseStudio/Recordings/`.

### Recording controls

- Start recording: `Command-R` from the Home screen.
- Stop recording: the floating Stop dock shown during recording, the menu-bar
  Stop item, or `Command-Shift-.`.
- Pause/resume while recording is not implemented yet; current scope is a
  visible Stop control.

### Known issue

The permission flow is still rough. Some local builds may continue to show
audio/video access prompts after access has been granted and the app has been
restarted. Use the bundled app path above, prefer a stable signing identity,
and treat repeated permission prompts as an active bug rather than expected
behavior.

### Without the bundle

`swift build && swift run BaseStudio` works for hacking, but the binary won't
have an `Info.plist` or entitlements — `AVCaptureSession` will crash on
camera/mic open. Always go through `build-app.sh` for capture.

---

## Test

```bash
swift test
```

24 tests, finishes in <1s. Coverage:

- `TimePoint` round-trip (PRD §1 invariant 3 — never store time as float).
- `TimeMap` PTS math under trim, speed remap, and stacked regions.
- `SourceClip.fileTime(at:)` — host-clock ↔ on-disk file-time conversion.
- `BSLog` file-backed logger round-trip.
- `ExportPipelineE2ETests` — synthesizes a `.basestudio` bundle, runs the
  full export pipeline, and reads the output mp4 back to assert the audio
  track is present *and audible* (peak |Int16| > 1000).

---

## Layout

```
Sources/
├── BaseStudioCore/         — Time, EDL, ProjectBundle (no AVFoundation deps)
├── BaseStudioRecording/    — ScreenRecorder, WebcamRecorder, MicRecorder,
│                             CursorRecorder, RecordingSession
├── BaseStudioRender/       — Renderer, Nodes/, ExportPipeline, AudioMixer,
│                             BackgroundImageStore, PolishPreset
├── BaseStudioPlayback/     — Compositor-backed preview player
└── BaseStudioApp/          — SwiftUI shell (Home, RecordingPanel, Editor)

Tests/
├── BaseStudioCoreTests/    — time + PTS + logger
└── BaseStudioRenderTests/  — full-pipeline export e2e

scripts/
├── build-app.sh            — build + sign the .app
├── setup-dev-cert.sh       — create the self-signed dev cert (one-time)
├── make-icon.swift         — regenerate AppIcon.icns from an SF Symbol
└── snap.swift              — screenshot the running app for design review

Resources/
├── Info.plist              — bundle metadata + camera/mic usage strings
└── BaseStudio.entitlements — hardened-runtime device entitlements
```

---

## Logs

Anything interesting written via `BSLog` lands in
`~/Library/Logs/BaseStudio/` as plain text. When something goes wrong on a
real recording session, send the latest log file — it has per-source PTS
anchors, the writer state machine, and timing from every async boundary.
