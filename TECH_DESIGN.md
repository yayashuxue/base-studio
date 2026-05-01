# Base Studio — Technical Design

Companion to `PRD.md`. The PRD says *what* won't break and *why*. This doc says *how the code is shaped* so that adding a new effect (manual zoom, follow-mouse zoom, noise removal, color grade, webcam overlay…) is a small, local change — not a cross-cutting one.

The core thesis:

> **Features are not code. Features are data — a node, a parameter schema, and a binding to a parameter source. The engine is fixed; the catalog grows.**

If adding "noise removal" requires touching the renderer, the scheduler, the export pipeline, or the timeline UI, the design failed. It should require: (1) one new file in `effects/`, (2) one entry in the registry. That's it.

---

## 1. Layer map

```
┌──────────────────────────────────────────────────────────────────┐
│  UI (SwiftUI)                                                    │
│   Timeline · Inspector · Preview Surface · Export Dialog         │
│   ── reflects EDL · auto-generated from node param schema ──     │
└──────────────────────────────────────────────────────────────────┘
                               │  (commands, never direct state)
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│  EDL Store    (single source of truth, immutable snapshots)      │
│   Project · Tracks · Segments · NodeGraph · KeyframeTracks       │
└──────────────────────────────────────────────────────────────────┘
                               │  (read-only)
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│  Renderer    (pure: (EDL, pts, quality) → (frame, audio_slice))  │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│   │ Video graph  │    │ Audio graph  │    │ Param resolver│      │
│   │ (Metal nodes)│    │ (DSP nodes)  │    │  (sources →   │      │
│   │              │    │              │    │   values @ t) │      │
│   └──────────────┘    └──────────────┘    └──────────────┘       │
└──────────────────────────────────────────────────────────────────┘
        ▲                                              ▲
        │                                              │
┌───────┴───────┐                            ┌─────────┴──────────┐
│  Sources      │                            │ Schedulers         │
│ media files + │                            │ Preview · Export   │
│ sidecar       │                            │ (only differ in    │
│ streams       │                            │  driving the PTS)  │
│ (cursor,      │                            │                    │
│  clicks,      │                            │                    │
│  audio meter) │                            │                    │
└───────────────┘                            └────────────────────┘
```

**The invariants from PRD §1 are the contracts between layers.** UI never reaches past EDL Store. Renderer never reads UI state. Schedulers never reach into the renderer's internals.

---

## 2. The Node abstraction (the part that makes features cheap)

Every effect — video or audio — is a `Node`. A Node is the unit of feature work. Adding `NoiseRemoval` and adding `FollowMouseZoom` use the *same* shape.

```swift
protocol Node {
    static var id: NodeID { get }                         // "zoom", "denoise"
    static var paramSchema: [ParamSpec] { get }            // declarative
    static var domain: Domain { get }                      // .video | .audio

    // Pure function. No state. No globals.
    func apply(input: Frame, params: ParamValues, ctx: RenderCtx) -> Frame
}
```

A `ParamSpec` declares one parameter:

```
ParamSpec { name, type, default, range, ui_hint, source_kinds_allowed }
```

`type` ∈ `{ scalar, point2, color, enum, curve, bool }`.

`source_kinds_allowed` is the key: it lists which **parameter sources** can drive this param. This is what makes one `Zoom` node serve three UX features.

---

## 3. Parameter sources (the part that makes UX features cheap)

A parameter value at time `t` is produced by a `ParamSource`. There are only a handful of source kinds, and they cover everything:

| Source kind        | Value at `t` is…                                       | Example use                                    |
|--------------------|--------------------------------------------------------|------------------------------------------------|
| `Constant`         | a fixed value                                          | "zoom = 1.0×"                                  |
| `Keyframed`        | piecewise interpolated over user-placed keyframes      | **Manual zoom** ramp the user drew             |
| `StreamBound`      | sampled from a sidecar stream                          | **Follow-mouse zoom** (bound to cursor stream) |
| `EventDriven`      | derived from discrete events with envelope             | **Auto-zoom on click** (bound to clicks)       |
| `Derived`          | a pure function of other params/streams                | "Zoom center = follow cursor with damping"     |

```swift
protocol ParamSource {
    func value(at t: CMTime, ctx: ResolveCtx) -> ParamValue
}
```

The Param resolver walks the EDL, finds the source bound to each param, and produces a `ParamValues` table for the current `t`. The Node just sees values — it does not know or care where they came from.

**This is the architectural payoff:** the `Zoom` node is *one* implementation. The three UX features are three different `ParamSource` bindings on its `center` and `scale` params:

- *Manual zoom:* `scale ← Keyframed`, `center ← Keyframed`
- *Follow-mouse zoom:* `scale ← Constant or Keyframed`, `center ← StreamBound(cursor)`
- *Auto-zoom on click:* `scale ← EventDriven(clicks, envelope)`, `center ← StreamBound(cursor) sampled at click PTS, held`

Adding a fourth flavor ("zoom to active window bounds") = a new sidecar stream + a new binding. Zero changes to the renderer.

---

## 4. The graph

```
            Segment (source clip on timeline)
                       │
                       ▼
                 [ Decode ]
                       │
                       ▼
                 [ SpeedCurve sampler ]   ◄── time remap from PRD §3
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   [ CursorPaint ] [ Zoom ]      [ ColorAdjust ]   ◄── nodes, ordered
                       │
                       ▼
                 [ BackgroundCompose ]
                       │
                       ▼
                  output frame

(Audio chain, parallel:)

         Source audio  ──►  [ SpeedCurve resample ]
                                     │
                              ┌──────┴──────┐
                              ▼             ▼
                        [ Denoise ]   [ Normalize ]
                              │             │
                              └──────┬──────┘
                                     ▼
                                output buffer
```

Per project, the graph is just a serializable list of `(node_id, params_with_sources)` per track. **The graph lives in the EDL.** Swapping order, disabling a node, adding a node — all are EDL edits.

---

## 5. Sidecar streams (the part that makes input data cheap)

Anything sampled densely over time that isn't pixels or audio is a **sidecar stream**. Defined uniformly:

```
Stream<T> { samples: [(pts, T)], interpolation: .step | .linear | .catmullRom }
```

Examples:
- `cursor: Stream<Point2>` — captured at 240 Hz during recording
- `clicks: Stream<MouseEvent>` — sparse, step interpolation
- `audio_rms: Stream<Float>` — derived offline after recording, at 100 Hz
- (future) `keystrokes`, `active_window`, `face_landmarks` from webcam

All sidecars live next to the source media in the project bundle. New input modality = new stream type + a recorder that writes it. Existing nodes can immediately bind to it via `StreamBound`.

---

## 6. Registry & plugin shape

```
effects/
├── video/
│   ├── Zoom.swift            // one file = one Node
│   ├── BackgroundCompose.swift
│   ├── CursorPaint.swift
│   └── ColorAdjust.swift
├── audio/
│   ├── Denoise.swift
│   └── Normalize.swift
└── Registry.swift            // one line per node
```

`Registry.swift` is the only "central" file:

```swift
let nodeRegistry: [NodeID: Node.Type] = [
    Zoom.id: Zoom.self,
    Denoise.id: Denoise.self,
    // ...
]
```

The UI Inspector, the EDL serializer, and the renderer all look up Nodes through the registry. **Adding a node never requires editing the renderer, the serializer, or the inspector.** They are all driven by `paramSchema`.

---

## 7. UI is generated, not hand-coded per feature

The Inspector pane is rendered from `paramSchema`. A `ParamSpec(type: .scalar, range: 1...10, ui_hint: .slider)` becomes a slider. A `ParamSpec(type: .point2, ui_hint: .canvasPicker)` becomes a click-on-preview picker. The "bind to source" menu is built from `source_kinds_allowed`.

Concretely, this means:
- New node ⇒ new inspector panel for free.
- New param ⇒ new control for free.
- A "follow mouse" toggle next to the zoom-center field is just the UI for *"change this param's source from `Keyframed` to `StreamBound(cursor)`."* No special-case code.

---

## 8. Worked example: adding noise removal

The whole change, end to end:

1. **`effects/audio/Denoise.swift`** — new file:
   ```swift
   struct Denoise: AudioNode {
       static let id: NodeID = "denoise"
       static let domain: Domain = .audio
       static let paramSchema = [
           ParamSpec("strength", .scalar, default: 0.5, range: 0...1,
                     uiHint: .slider, sourceKindsAllowed: [.constant, .keyframed]),
           ParamSpec("noiseProfile", .enum(["auto", "manual"]), default: "auto",
                     uiHint: .picker, sourceKindsAllowed: [.constant]),
       ]
       func apply(input: AudioBuffer, params: ParamValues, ctx: RenderCtx) -> AudioBuffer {
           // RNNoise / spectral subtraction, pure function of input + params
       }
   }
   ```
2. **`effects/Registry.swift`** — one new line: `Denoise.id: Denoise.self`.
3. **Tests** — drop a fixture audio file in `Tests/Fixtures/`, write one parity test:
   - render with denoise via preview path and export path, assert sample-identical (PRD §5a).

That's it. No renderer change. No EDL schema migration (the EDL stores `(node_id, params)`, both are open). No UI change. No export-pipeline change. Inspector picks up the new node automatically.

---

## 9. Worked example: adding manual zoom + follow-mouse zoom together

If `Zoom` is already defined with `center: point2`, `scale: scalar`, and both params declare `sourceKindsAllowed: [.constant, .keyframed, .streamBound, .eventDriven]`, then:

- **Manual zoom:** UI lets the user place keyframes. Saves `center.source = Keyframed(...)`, `scale.source = Keyframed(...)`.
- **Follow-mouse zoom:** UI offers a "Follow cursor" toggle on the center field. Toggling sets `center.source = StreamBound(cursor)`. Done.
- **Auto-zoom on click:** the recorder already wrote the click stream; UI offers an "Auto-zoom on clicks" preset that sets `scale.source = EventDriven(clicks, envelope: bumpUpFor(0.6s))` and `center.source = StreamBound(cursor)`.

All three coexist on the same segment because they bind different params or different time ranges (a `ParamSource` is per-param, per-segment, and can itself be a piecewise composition).

**Zero new node code for any of the three.** The work is in *one* `Zoom` node that takes the abstraction seriously.

---

## 10. Where complexity is allowed to live

Some things are genuinely hard and we don't pretend otherwise. They get isolated, *not* spread:

- **`SpeedCurve` time remapping** — lives in one module, used by `SpeedCurve sampler` (video) and `SpeedCurve resample` (audio). The math is in one place; nodes don't need to know.
- **Param resolution with sources** — lives in `ParamResolver`. Nodes receive resolved values. They never see `ParamSource`.
- **GPU pipeline state** — lives in `MetalContext`. Video nodes get a render encoder; they don't manage pipelines.
- **Audio buffer alignment** — lives in `AudioGraph`. DSP nodes process aligned blocks; they don't worry about timeline PTS.

The principle: **hard cross-cutting concerns are solved once, in a fixed engine. Feature work happens only at the leaves.**

---

## 11. Anti-patterns we will reject in review

These sound reasonable and will quietly destroy the architecture:

- *"Let's add an `is_followMouse` flag to the Zoom node."* → No. That's a new ParamSource binding, not a new code path.
- *"Noise reduction needs access to the timeline to know what's silence."* → No. It needs a sidecar stream (`audio_rms`) computed once, then bound as a param source.
- *"This effect is special, it needs its own renderer entry point."* → No. If the Node contract can't express it, we extend the contract once for everyone, never for one effect.
- *"Just call AVFoundation here, it's easier."* → Only inside the engine layer (decoders, encoders). Never inside a Node. Nodes are pure.
- *"We'll add the registry entry later, hardcoded for now."* → No. The registry is the API; bypassing it means the inspector and serializer don't see the node, and the bug surfaces three weeks later in export.

---

## 12. Test architecture mirrors the code architecture

- **Engine-level tests** (rare to change): EDL invariants, param resolver, speed curve, renderer purity, preview/export parity (PRD §5a).
- **Node-level tests** (one per node): given input frame/buffer + params, assert output. No engine knowledge needed.
- **Integration tests** (per UX feature): "place keyframes via UI commands, render, verify result." These are the only place UX features have a dedicated test.

Adding a new node ⇒ add a node-level test next to it. The engine-level tests catch you if you broke a contract; the integration tests catch you if you broke a user-visible flow. There is no "renderer test" you have to update for a new effect — and that absence is the whole point.
