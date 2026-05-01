# Base Studio — PRD

A Screen Studio–style macOS app for recording the screen and producing polished, animated videos (auto-zoom on clicks, smooth cursor, padded backgrounds, speed ramps, captions).

The product surface is well-trodden. **This PRD is mostly about the architectural decisions that prevent the failure modes that historically kill apps in this category**: scrubber jank, dropped frames on export, A/V desync after speed ramps, and crashes on long timelines. Those failures are not bugs — they are symptoms of the wrong abstractions chosen early. We name the abstractions here.

---

## 1. Non-negotiable invariants

These are the rules every subsystem must obey. If a feature request would violate one, the feature changes — not the invariant.

1. **Source media is immutable.** Recording produces files on disk; nothing in the editor ever rewrites them. All edits live in an Edit Decision List (EDL).
2. **One clock.** Playback, scrubbing, and export all derive presentation time from a single monotonic timeline clock. No subsystem keeps its own "current time."
3. **PTS, not frame index.** All time is expressed in rational presentation timestamps (e.g. `CMTime` / `{value, timescale}`). Never in `float seconds` for storage, never in `frame_number` for cross-subsystem APIs. Float is fine for UI display only.
4. **Sample-accurate audio.** Audio timeline operates at sample granularity (48 kHz). Video frames snap to audio, not the other way around.
5. **Preview and Export share one renderer.** They differ *only* in scheduler and quality tier — never in time math, never in effect math, never in audio mixing. See §5a.
6. **Determinism.** Given the same EDL + source media + export settings, the output is byte-identical. No wallclock, no RNG, no "best effort" frame picking.

---

## 2. The Edit Decision List (EDL)

The EDL is the single source of truth for "what the video is." Everything — preview, scrubber thumbnails, export — reads from it. Nothing else holds edit state.

```
Project
├── sources: [SourceClip]          # immutable refs to recorded files
├── tracks:
│   ├── video: [Segment]            # ordered, non-overlapping on the timeline
│   ├── audio: [Segment]            # sample-accurate
│   └── effects: [EffectNode]       # zoom, cursor, background, captions
└── timeline_duration: CMTime
```

A `Segment` is `{ source_id, source_in: CMTime, source_out: CMTime, timeline_in: CMTime, speed_curve: SpeedCurve }`.

**Why this matters for the failure modes you've hit:**

- **Scrubber crashes from "missing frames":** the scrubber asks the EDL for the frame at timeline-time `t`. The EDL maps `t` → `(segment, source_time)`. If the source can't deliver, the renderer returns the *last known good frame* plus a `stale=true` flag — never null, never throw. The UI never sees an exception path.
- **Speed ramps desyncing audio:** speed lives on the segment as a `SpeedCurve` (piecewise function), not as a "rendered fast clip." Time mapping is mathematical, not generative. Audio resampling is computed from the same curve, so they cannot drift.

---

## 3. Time remapping (the speed-ramp problem)

This is the subsystem you've been burned by. Spelling it out:

A `SpeedCurve` on a segment is a monotonic function `f: timeline_time → source_time`. Constant speed is a line; ramps are piecewise linear or eased. The curve is the *only* representation of speed — there is no "we sped up frames 100–200" cached state.

- **Video sampling:** for timeline frame at time `t`, compute `s = f(t)`, fetch source frame at `s` (with optical-flow interpolation if `|f'(t)| < 1`, frame blending or drop if `> 1`). Pure function of `(EDL, t)`.
- **Audio resampling:** the same `f(t)` drives a time-domain resampler (WSOLA for ≤4× preserving pitch; linear resample for extreme ramps with explicit pitch-shift opt-in). Audio is generated *per export*, not pre-baked.
- **Preview shortcut:** preview may use nearest-frame + linear audio resample for speed; export must use the high-quality path. Both read the same `f(t)`. Quality differs; *timing does not*.

**The bug class this kills:** "I sped up a section, exported, and the audio is 200ms behind by the end." That happens when video and audio compute speed independently. Here they cannot — there is one `f(t)`.

---

## 4. Playback / preview pipeline

```
Timeline Clock (CADisplayLink-driven, monotonic)
       │
       ▼
   Scheduler ──► VideoFrameRequester ──► Decoder Pool ──► GPU Compositor ──► CAMetalLayer
       │                                                      ▲
       └──────► AudioRenderer (AVAudioEngine, sample-clock) ───┘ (sync)
```

Rules:
- The clock advances; the scheduler asks "what frame do I need at `t + lookahead`?" It does *not* push frames at a rate.
- Frame requests are cancelable. Scrubbing rapidly cancels in-flight decodes — this is the difference between a buttery scrubber and one that locks up.
- Decoder pool has a bounded LRU cache keyed by `(source_id, source_pts)`. Memory cap is explicit, not "whatever the OS allows."
- A/V sync is enforced by the audio clock: video frames are presented when the audio sample at their PTS plays. If video is late, drop. If early, wait. Never the reverse — humans notice audio glitches far more than video drops.

---

## 5a. Preview/Export parity contract

This is the architectural fix for *"preview looks right, export is wrong."* That bug only happens when preview and export are two pipelines that drifted. We make it impossible by construction:

```
                   ┌───────────────────────────────┐
                   │         Renderer              │
                   │  pure fn (EDL, pts, quality)  │
                   │       → (frame, audio_slice)  │
                   └───────────────┬───────────────┘
                                   │
                ┌──────────────────┴──────────────────┐
                ▼                                     ▼
     PreviewScheduler                          ExportScheduler
     (clock-driven, can drop)                  (pts-iterating, never drops)
```

Rules that make parity enforceable, not aspirational:

- **The renderer is a pure function.** No `is_preview` parameter. No global state. Inputs: `(EDL, pts, quality_tier, source_reader)`. Outputs: a frame and an audio slice. Same inputs → same outputs, always.
- **`quality_tier` is a numeric enum** (`draft`, `standard`, `high`) that controls only: interpolation algorithm, shader precision, audio resampler kernel. It does **not** change *what* gets rendered, only *how well*. Geometry, timing, effect parameters, and color are identical across tiers.
- **No engine does its own time math.** Preview does not call `AVAudioEngine` to "play the project" — it calls the renderer at PTSes the clock asks for, then hands the resulting buffer to the audio engine for playback. Export does the same, just iterating PTSes instead of following a clock. Same renderer call, same numbers in.
- **No engine does its own resampling.** AVAudioEngine, AVPlayer, AVAssetReader all helpfully resample if you let them. We disable that and resample ourselves, in the renderer, from the `SpeedCurve`. One implementation, not three.
- **Float determinism.** Renderer uses fp32 on GPU with a fixed Metal pipeline; rounding modes are pinned. Export and preview at the same `quality_tier` produce pixel-identical output, not "visually similar."

**The test that enforces this** (added in M1, runs on every PR):

> *Parity test:* pick a project, pick 20 random PTSes. Render each via the preview path (driven by a mock clock) and via the export path. Assert frames are pixel-identical at `quality_tier=high`, and audio buffers are sample-identical. Tolerance: zero.

If this test ever needs a tolerance, the architecture broke and we fix it before merging. This is the test that catches "export came out wrong" *before* anyone exports anything.

A subtler corollary: **what you see in preview at `quality_tier=high` IS what export produces.** The "Preview Quality" dropdown in the UI is literally the `quality_tier` knob. Users can preview at draft for speed and at high to verify export.

---

## 5b. Export pipeline

This is where "vibe-coded" apps fail. Export is **not** "play the timeline and capture the output." Export is an offline render:

```
for each output_frame_pts in [0, duration] step (1/fps):
    video_frame = renderer.render(EDL, output_frame_pts)   # pure
    encoder.append(video_frame, pts=output_frame_pts)

audio_buffer = audio_renderer.render(EDL, [0, duration])    # pure, sample-accurate
encoder.append_audio(audio_buffer)

encoder.finalize()
```

- **Single-threaded by default.** Parallelism is a later optimization, gated behind determinism tests. Premature parallelism is how export pipelines grow heisenbugs.
- **Backpressure.** The encoder pulls; the renderer is synchronous. No queues that can grow unbounded.
- **Progress = `current_pts / duration_pts`.** Not "frames done / frames total" (wrong with VFR sources), not "bytes written / estimate" (wrong always).
- **Cancellation is a first-class state**, not a flag checked between frames. A canceled export leaves no partial file (write to temp, atomic rename on success).
- **Memory profile is flat.** Each frame allocates and releases. No accumulating buffers. Test with a 30-minute timeline before shipping anything.

---

## 6. Recording

- Capture via `ScreenCaptureKit` (macOS 13+). Microphone via `AVCaptureSession`, system audio via SCK's audio capture.
- Write straight to disk as `.mov` with H.264 or HEVC, plus a sidecar `.cursor.json` containing `[(timestamp_ns, x, y, event_type)]` sampled at 240 Hz.
- **Cursor data is captured separately, not burned into the video.** This is what enables smooth cursor and auto-zoom in the editor without re-detecting the cursor from pixels.
- Click events recorded with absolute timestamps from the same monotonic clock as the video frames' PTS. Mismatched clocks here = auto-zoom triggering at the wrong moment forever.

---

## 7. Effects (the visible product surface)

Implemented as pure functions `(input_frame, params, t) → output_frame` in a Metal shader graph. Each effect is a node; the compositor walks the graph per frame.

MVP set:
- **Auto-zoom on click** — driven by `.cursor.json`, with configurable ease and hold duration. Zoom target = cursor position at click PTS.
- **Smooth cursor** — replace OS cursor with rendered cursor at interpolated position (Catmull-Rom over the 240 Hz samples).
- **Background** — solid / gradient / image, with inset + corner radius + shadow on the recording.
- **Speed ramps** — UI for adding ramps; underneath it is just editing the `SpeedCurve`.
- **Captions** — burned-in at export, live overlay in preview. Source: Whisper (local, `whisper.cpp`) on the audio track.
- **Webcam overlay** — circular crop, corner placement (4 presets) with configurable size + shadow. Captured as a parallel source during recording (`webcam.mov` in the bundle), aligned via host-clock PTSes; rendered as a node whose input is fetched from the webcam source clip, not the primary screen source.

Out of scope for v1: multi-track screen video, transitions, color grading.

---

## 8. Tech stack

- **Language:** Swift for app shell, AppKit + SwiftUI for chrome.
- **Rendering:** Metal directly (not SpriteKit/SceneKit). The compositor is small enough to own.
- **Decode/encode:** AVFoundation (`AVAssetReader` / `AVAssetWriter`). VideoToolbox for hardware accel.
- **Audio:** AVAudioEngine for preview, manual buffer rendering for export.
- **Storage:** Project file is a directory bundle (`.basestudio`) containing `edl.json` + symlinks/copies of source media. Human-readable EDL is non-negotiable for debugging.

---

## 9. Test strategy that catches the failure modes upfront

These tests exist from week one, not after the first crash report:

1. **Determinism test.** Export the same project twice; assert byte-identical output. Run on every PR.
1a. **Preview/Export parity test.** As described in §5a — preview-rendered frames at `quality_tier=high` match export-rendered frames pixel-for-pixel, audio sample-for-sample. Zero tolerance.
2. **A/V drift test.** Export a 30-minute timeline with multiple speed ramps. Assert audio and video PTS at the end agree to within one audio sample.
3. **Long-timeline memory test.** Export a 60-minute timeline; assert peak RSS stays under a fixed cap (e.g. 1.5 GB).
4. **Scrubber fuzz test.** Programmatically scrub randomly for 60 seconds; assert no exceptions, no frame-fetch returns null, FPS stays above 30.
5. **EDL round-trip test.** Save → load → save; assert identical bytes.
6. **Speed-curve invariant test.** For every supported curve, assert `f` is monotonic and `f(0) = source_in`, `f(duration) = source_out` to sample precision.

If a test in this list is hard to write, the architecture is wrong — fix the architecture, not the test.

---

## 10. Milestones

1. **M0 — Recording + raw playback.** SCK capture, cursor sidecar, dumb player. No effects, no editing.
2. **M1 — EDL + scrubber.** Trim, split, scrub. Single-speed only. All six tests above passing for this scope.
3. **M2 — Export pipeline.** Offline render to mp4. Determinism + A/V drift + long-timeline tests passing.
4. **M3 — Effects: background, smooth cursor, auto-zoom.**
5. **M4 — Speed ramps.** This is the milestone where everything from §3 must already be true. Adding speed ramps should be small at this point — the curve plugs into the existing time-mapping path. If it's a big change, §2 was implemented wrong and we go back.
6. **M5 — Captions, polish, ship.**

---

## 11. What we are explicitly *not* doing

- No "render the speed-up to a temp file then play it back." This is the shortcut that causes the desync you've hit. Time mapping is always mathematical.
- No global mutable state for "current time." The clock is injected.
- No hidden caches that survive across edits. Caches are keyed by EDL hash + time; an edit invalidates them by construction.
- No best-effort frame interpolation in export. Export uses one chosen algorithm per project; "looks fine" is not a spec.
