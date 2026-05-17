# Captions + Bug #8 Checkpoint — Implementation Plan

Day-0 scaffold doc for the Phase B GTM blockers. Written so anyone (including a future me after context loss) can resume mid-stream and ship without re-deriving the design.

Status: **scaffold** — no production code wired yet. Awaiting julie's priority lock between base-studio Phase B vs clip-cutter "Learn Anything" MVP.

---

## 1. Captions (post-record, Whisper.cpp local)

### Goal

When a user finishes a recording, generate burnable word-pop subtitles from the audio track without any cloud round-trip. Ship a "Captions" inspector panel where the user picks a style (Impact-pop / clean-minimal / brand-color), reviews/edits the transcript, then re-renders the export with captions baked in.

### Why post-record (not realtime)

- Realtime captions = streaming Whisper + UI rendering of partial hypotheses while recording = adds CPU pressure to the already-fragile recording path
- 90% of the GTM value comes from "captions on the exported video", not "see your words as you talk"
- Whisper.cpp on M1/M2 transcribes a 5-min recording in ~30s with the `small.en` model. UX is "click Export → captions ready in seconds"

### Pipeline

```
Recording finishes
  └─> ProjectBundle has screen.mov (with audio) + (optional) mic.m4a
        └─> CaptionGenerator.generate(audioURL:)
              ├─> AudioExtractor: AVAssetExportSession → 16kHz mono WAV (Whisper input format)
              ├─> WhisperRunner: load model → call whisper_full → word-level segments [{start, end, text, words: [{start, end, text}]}]
              └─> ASSWriter (port from clip-cutter/cut_and_burn.py): word-pop dialogue per word, Impact style
        └─> Export pipeline picks up captions.ass and adds `subtitles=...` filter to ffmpeg vf chain
```

### Whisper.cpp integration

- **Binary**: build `libwhisper.a` once via cmake, vendor into Sources/BaseStudioCaptions/whisper.xcframework (universal Apple Silicon + x86_64). ~3MB
- **Model**: ship `ggml-small.en.bin` (~487MB) as on-demand download from huggingface on first use (don't bloat the .dmg). Cache to `~/Library/Application Support/BaseStudio/models/`. Show a one-time progress UI.
- **Swift FFI**: thin Swift wrapper around the C API (whisper_init_from_file / whisper_full / whisper_full_get_segment_text / whisper_full_get_token_t0). ~200 LOC.
- **Word timestamps**: pass `wparams.token_timestamps = true` to get per-token timing → group tokens into words via whitespace.
- **Reference**: github.com/ggerganov/whisper.cpp/blob/master/examples/main/main.cpp

### ASS render (reuse from clip-cutter)

Port `cut_and_burn.py:build_ass` to Swift. Core logic:
- One Dialogue line per word
- Active word: `{\b1\fscx150\fscy150\t(0,120,\fscx125\fscy125)}` (yellow/green pop)
- Non-active: `{\b1\c&HFFFFFF&}` (plain white bold)
- Wrap at chars_per_line (configurable per style preset)

90% of the logic is string formatting — port is mechanical.

### Files to add

```
Sources/BaseStudioCaptions/
├── WhisperRunner.swift           (Swift wrapper around whisper.cpp C API)
├── CaptionGenerator.swift        (orchestrates extract→transcribe→render)
├── ASSWriter.swift               (port of cut_and_burn.py:build_ass)
├── CaptionStyle.swift            (style preset model)
└── WhisperModelDownloader.swift  (on-demand model fetch + cache)

Sources/BaseStudioRender/
└── ExportPipeline.swift          (modify: add captions.ass to ffmpeg vf if present)

Sources/BaseStudioApp/Editor/
└── CaptionsInspectorView.swift   (panel: style picker, transcript edit, regenerate)
```

### Estimate

- Day 0 evening: whisper.cpp build + Swift FFI wire-up + smoke test (transcribe a sample wav → console print)
- Day 1: ASS port + export pipeline integration + headless E2E test
- Day 2: inspector panel UI + style presets + transcript edit
- Day 3: model download UX + on-first-launch flow polish + ship

**Total: 3-4 days.** Critical path = whisper.cpp build (1 evening once, rebuilt rarely).

---

## 2. Bug #8 Checkpoint — Crash-Recovery Recording

### Goal

Physically eliminate the 0-byte `screen.mov` failure mode. Even if `AVAssetWriter` corrupts mid-session, the user loses at most 60 seconds (the last in-flight segment), not the entire recording.

### Design: writer rotation

Current code (`ScreenRecorder.swift:212`):
- One `AVAssetWriter` for the whole session, writing to `screen.mov`
- On stop: `finishWriting()` — if this fails, file is corrupt/empty

New design:
- Maintain a rotating `AVAssetWriter` that writes to `screen_part_NNN.mov` (NNN = monotonic)
- Rotate every 60s OR every N keyframes (whichever first), using SCK's `outputFrames` counter
- On rotate: `videoInput.markAsFinished()` → `await writer.finishWriting()` → open new writer → re-add inputs → continue appending to the new one
- Track segment list in `screen_segments.json` alongside the segments (atomic write each rotation)
- On `stop()`: finish the last segment → compose final `screen.mov` via `AVMutableComposition` (zero re-encode, instant)
- On app launch: scan project bundle for orphaned `screen_part_*.mov` + `screen_segments.json` → if last rotation timestamp >5s ago and no `screen.mov` exists, auto-compose the recovered segments and surface a banner "Recovered N seconds from interrupted session"

### Why this works

- Rotation is well-supported by AVFoundation (each writer is independent, no shared state)
- Composition is metadata-only (no re-encode) — instant even for 2-hour recordings
- Single point of failure (one big writer) becomes N independent points (one fails = lose only that 60s)
- Recovery is automatic, not manual

### GTM framing (per cc)

Not "long session still in beta" (defensive).
Instead: **"Automatic 60-second crash recovery — losing a long recording is impossible by design."** Goes straight onto landing as a USP feature.

### Files to modify

```
Sources/BaseStudioRecording/
├── ScreenRecorder.swift          (refactor: writer becomes WriterSegmentRotator)
└── (new) WriterSegmentRotator.swift   (encapsulates rotation + segment manifest)

Sources/BaseStudioCore/
├── ProjectBundle.swift           (add: load/save segment manifest, compose final mov)
└── (new) RecoveryScanner.swift   (app-launch scan for orphaned segments)

Sources/BaseStudioApp/
└── ContentView.swift             (banner UI for "recovered N seconds")
```

### Estimate

- Day 0 evening: `WriterSegmentRotator` skeleton + unit test for rotation + recompose roundtrip
- Day 1: wire into `ScreenRecorder` + segment manifest atomic write + integration test
- Day 1 EOD: recovery scanner + banner UI

**Total: 1-1.5 days.** Independent of captions work, can run in parallel.

---

## 3. Notarize + Sparkle

### Apple Developer requirements (hard gate)

- $99/yr Apple Developer Program membership
- Developer ID Application certificate (in Keychain)
- App-specific password OR API key for notarytool
- Hardened runtime entitlements review (already mostly set in `Entitlements.entitlements`)

If julie doesn't have an account yet: 24-48h approval window blocks this entirely. **Ask first.**

### Notarize workflow (script)

```
swift build -c release
# bundle into .app
codesign --deep --force --options runtime --sign "Developer ID Application: ..." BaseStudio.app
ditto -c -k --keepParent BaseStudio.app BaseStudio.zip
xcrun notarytool submit BaseStudio.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple BaseStudio.app
hdiutil create -volname "BaseStudio" -srcfolder BaseStudio.app -ov -format UDZO BaseStudio.dmg
```

Wrap into `scripts/release.sh`.

### Sparkle setup

- Add Sparkle via SPM (`https://github.com/sparkle-project/Sparkle`)
- Generate EdDSA key pair, embed public key in Info.plist
- Host `appcast.xml` at e.g. `https://basestudio.app/appcast.xml`
- Each release: generate signature with `sign_update`, append `<item>` to appcast

### Estimate

- 1 day if Apple Dev account is ready
- 2 days if cert + provisioning needs setup

---

## 4. Day-by-day plan (parallel tracks)

Assumes julie greenlights base-studio path on Day 0 morning.

| Day | Captions (me) | Checkpoint (me) | Notarize (me) | GTM (cc) |
|-----|---------------|------------------|---------------|----------|
| 0 evening | whisper.cpp build + FFI smoke test | WriterSegmentRotator skeleton + test | (blocked on Apple Dev) | names + landing wireframe + DM templates |
| 1 | ASS port + export integration + E2E | wire to ScreenRecorder + manifest | start when Dev account ready | 12 ICP list + Gumroad page draft |
| 2 | inspector UI + style presets | recovery scanner + banner | sign + notarize first build | landing copy lock + demo script |
| 3 EOD | ship + on-launch model download | ship | sign+notarize automation script | landing deploy (no demo embed yet) |
| 4 | (julie records demo with captioned build) | — | release.sh polish | demo upload + embed |
| 5-7 | on-call PH bugs | on-call | — | Gumroad live + design partner DMs + PH launch |

---

## 5. What's NOT in scope

Explicitly deferred — not because they don't matter, but because they blow the 1-week ship:
- Realtime captions (post-record covers GTM)
- Multi-language transcription (English only, ship later)
- Caption animation library beyond word-pop + minimal (2 styles → ship; more = M4)
- Bug #8 root-cause investigation (checkpoint mitigation eliminates user-facing impact; root-cause stays in `git log` follow-up)
- Cloud-based caption fallback (Whisper.cpp local is enough; AssemblyAI/Deepgram are V2 quality option)

---

## 6. Open questions (for julie)

1. Apple Developer account: registered already? (Hard gate for notarize → no answer = 1-2 day push to right edge of timeline)
2. Whisper model size: ship `small.en` (487MB, fast, 95% accuracy) or `base.en` (148MB, faster, 92% accuracy)? My recommend: `small.en`, accuracy matters more than 340MB save on a one-time download.
3. Caption styles for V1: ship 1 style (Impact-pop, our clip-cutter default) or 2 (+ minimal-clean for corporate demos)? Recommend: ship 1, more is M4.

---

## 7. References

- whisper.cpp main loop: https://github.com/ggerganov/whisper.cpp/blob/master/examples/main/main.cpp
- AVAssetWriter segment patterns: https://developer.apple.com/documentation/avfoundation/avassetwriter
- AVMutableComposition recipe: https://developer.apple.com/documentation/avfoundation/media_composition_and_editing
- Sparkle SPM integration: https://sparkle-project.org/documentation/
- notarytool: `xcrun notarytool --help`
