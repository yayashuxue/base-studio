# Base Studio — feature checklist

How each feature is checked. **Auto** = automated test (runs in `swift test`).
**Live** = needs a real recording on the Mac (`scripts/selftest-guarded.sh` with
the listed self-test flags, or by hand). Status as of 2026-11-09.

## Recording

| Feature | How it's checked | Status |
|---|---|---|
| Screen + system audio capture | Live: `--selftest-record --selftest-export-each` | passed 11/1 (60 s) |
| Mic, webcam tracks | Live: same, with webcam | passed 11/1; julie's 11/9 take: webcam 29.7 fps, audio gap-free |
| Encoder failure mid-take → recover | Auto: ScreenSegmentStitchTests; Live: `BS_INJECT_SCREEN_FAIL_AT_*` | passed |
| Static / locked screen keeps full length | Live: fragment probes | passed |
| 52 s picture+sound loss (10/31) | Capture watchdog logs every 5 s | **open — release gate** |
| Own windows (control bar, camera bubble) not recorded | Live: `--selftest-camera-bubble`, frame check | pending live |
| Camera self-view from the countdown | Live (needs camera) | pending live |
| Control bar: timer, Stop, Restart, Pause/Resume | Auto: TakeStartGateTests, snapshots; Live | pending live |
| Shortcuts ⌥⇧S / ⌘⇧. stop, ⌥⇧R restart, ⌥⇧P pause | Live (Carbon hot keys) | pending live |
| Pause writes nothing (screen, system audio, webcam, mic, cursor) | Auto: PauseStateTests, SelfTestPauseCheckTests; Live: `--selftest-pause 20 10`, `--selftest-pause-stop 15` | pending live |
| macOS "Stop Sharing" finishes the take | Auto: CaptureEndedTests | pending live |
| Never overwrite an existing take | Auto: ProjectBundleCreateTests | passed |
| Permissions before countdown (mic, camera); screen via real error | Code audit (task #15) | passed |
| Cursor positions | Auto: CursorAndFitTests; Live: `--selftest-cursor-tour` (corners + centre ≤ 3 pt) | offline OK on julie's take; pending live |
| Click ripple / click zoom at the click | Offline: julie's 11/9 clicks = cursor samples (< 4 ms) | pending live frames |

## Editor

| Feature | How it's checked | Status |
|---|---|---|
| Playback with sound, picture in sync | Auto: testPreviewItemFollowsSpeedAndCutInSync, PreviewClockTests | fixed offline; fps under load ~20 — **live fps check** |
| Pause / scrub keeps sound aligned | Auto: PreviewClockTests | pending live |
| Speed regions (zoom region speed 1–2×) | Auto: preview + export tests; julie's take exports 2× correctly | pending live (julie saw old preview) |
| Cuts (pauses) close up the timeline | Auto: TimeMapCutTests, EditorCutMappingTests, testCutClosesUpAndKeepsSync | passed offline |
| Zoom regions (auto from clicks, manual, follow cursor) | Existing behaviour | to check live |
| Background presets / custom image | Export renders custom image (julie's HEIC) | **ask julie where it fails** |
| Background off → screen fits canvas | Auto: CursorAndFitTests | passed offline |
| Webcam overlay shape / corner | Existing behaviour | to check live |
| Captions (on-device transcription) | Existing behaviour | to check live |
| Undo / redo, autosave | Existing behaviour | to check live |

## Export

| Feature | How it's checked | Status |
|---|---|---|
| A/V sync (Apple + ffmpeg decoders) | Auto: ExportAVSyncTests | passed |
| Long takes, memory bounded | Auto: ExportMemoryTests; replay of 330 s take (669 s, peak 122 MB) | passed |
| Cuts and speed in export | Auto: ExportAVSyncTests cut test; probe on julie's take | passed |

## Library

| Feature | How it's checked | Status |
|---|---|---|
| Open / rename / reveal / delete recordings | Existing behaviour | to check live |
