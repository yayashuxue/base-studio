import BaseStudioCore
import SwiftUI

/// Right-side panel of the editor. Auto-builds controls per known node type.
/// Mutations go through `EditorState`, which triggers a render.
struct InspectorView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var vm: RecordingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inspector")
                    .font(.title3.bold())
                    .padding(.bottom, 4)

                canvasSection
                Divider().opacity(0.2)

                exportSection
                Divider().opacity(0.2)

                if let regID = state.selectedRegionID,
                   let region = state.project.zoomRegions.first(where: { $0.id == regID }) {
                    selectedRegionSection(region)
                    Divider().opacity(0.2)
                }

                ForEach(state.project.nodeGraph.nodes, id: \.instanceID) { instance in
                    nodeSection(for: instance)
                    Divider().opacity(0.2)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)
            HStack(spacing: 6) {
                ForEach(RecordingViewModel.ExportResolution.allCases) { res in
                    Button(action: { vm.exportResolution = res }) {
                        Text(res.label)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(
                                vm.exportResolution == res
                                    ? Color.accentColor.opacity(0.7)
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(targetDimsLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("≈\(estimatedBitrateMbps) Mbps")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("Audio").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            HStack(spacing: 6) {
                ForEach(RecordingViewModel.ExportAudio.allCases) { mode in
                    Button(action: { vm.exportAudio = mode }) {
                        VStack(spacing: 2) {
                            Image(systemName: mode.icon).font(.system(size: 11))
                            Text(mode.label).font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            vm.exportAudio == mode
                                ? Color.accentColor.opacity(0.7)
                                : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var targetDimsLabel: String {
        let canvas = state.project.canvas
        if let h = vm.exportResolution.heightPx {
            let aspect = Double(canvas.widthPx) / Double(canvas.heightPx)
            let w = Int(Double(h) * aspect) & ~1
            return "\(w)×\(h)"
        }
        return "\(canvas.widthPx)×\(canvas.heightPx)"
    }
    private var estimatedBitrateMbps: Int {
        vm.exportResolution.defaultBitrate / 1_000_000
    }

    // MARK: - Canvas (aspect ratio)

    @ViewBuilder
    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Canvas").font(.headline)
            HStack(spacing: 6) {
                ForEach(CanvasSpec.presets, id: \.self) { preset in
                    Button(action: { state.setCanvas(preset) }) {
                        VStack(spacing: 3) {
                            // Tiny aspect-ratio glyph.
                            let w: CGFloat = 22 * CGFloat(preset.widthPx) / CGFloat(max(preset.widthPx, preset.heightPx))
                            let h: CGFloat = 22 * CGFloat(preset.heightPx) / CGFloat(max(preset.widthPx, preset.heightPx))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(state.project.canvas == preset
                                      ? Color.accentColor
                                      : Color.white.opacity(0.25))
                                .frame(width: w, height: h)
                                .frame(width: 22, height: 22)
                            Text(preset.label).font(.system(size: 10))
                        }
                        .frame(width: 50, height: 44)
                        .background(
                            state.project.canvas == preset
                                ? Color.accentColor.opacity(0.15)
                                : Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func selectedRegionSection(_ region: ZoomRegion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Zoom Region").font(.headline)
                Spacer()
                Button(action: { state.deleteZoomRegion(region.id) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
            }

            HStack {
                Text("Scale").font(.caption)
                Spacer()
                Text(String(format: "%.2f×", region.scale))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Discrete preset buttons (Screen Studio-style).
            HStack(spacing: 6) {
                ForEach([1.2, 1.4, 1.6, 1.8, 2.0, 2.5], id: \.self) { v in
                    Button(action: {
                        state.updateZoomRegion(region.id) { $0.scale = v }
                    }) {
                        Text(String(format: "%.1f×", v))
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(
                                abs(region.scale - v) < 0.05
                                    ? Color.purple.opacity(0.7)
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle("Follow cursor", isOn: Binding(
                get: { region.followCursor },
                set: { v in state.updateZoomRegion(region.id) { $0.followCursor = v } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Speed picker (Screen Studio-style discrete buttons).
            HStack {
                Text("Speed").font(.caption)
                Spacer()
                Text(String(format: "%.1f×", region.speed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach([1.0, 1.2, 1.4, 1.6, 1.8, 2.0], id: \.self) { v in
                    Button(action: {
                        state.updateZoomRegion(region.id) { $0.speed = v }
                    }) {
                        Text(v == 1.0 ? "1×" : String(format: "%.1f×", v))
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(
                                abs(region.speed - v) < 0.05
                                    ? Color.accentColor.opacity(0.7)
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("Transition").font(.caption)
                Spacer()
                Text(String(format: "%.2fs", region.transitionSec))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { region.transitionSec },
                    set: { v in state.updateZoomRegion(region.id) { $0.transitionSec = v } }
                ),
                in: 0.05...1.5
            )
        }
    }

    @ViewBuilder
    private func nodeSection(for inst: NodeInstance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(displayName(for: inst.nodeType))
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { inst.enabled },
                    set: { state.setNodeEnabled(instanceID: inst.instanceID, $0) }
                )).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            controls(for: inst)
                .opacity(inst.enabled ? 1 : 0.4)
                .disabled(!inst.enabled)
        }
    }

    private func displayName(for id: String) -> String {
        switch id {
        case "background_compose": return "Background"
        case "zoom": return "Auto Zoom"
        case "cursor_paint": return "Cursor"
        case "click_bubble": return "Click Bubble"
        case "webcam_overlay": return "Webcam"
        case "caption_overlay": return "Captions"
        default: return id
        }
    }

    @ViewBuilder
    private func controls(for inst: NodeInstance) -> some View {
        switch inst.nodeType {
        case "background_compose":
            backgroundControls(inst)
        case "zoom":
            zoomControls(inst)
        case "cursor_paint":
            cursorControls(inst)
        case "click_bubble":
            bubbleControls(inst)
        case "webcam_overlay":
            webcamControls(inst)
        case "caption_overlay":
            captionControls(inst)
        default:
            Text("(no editor)").foregroundStyle(.tertiary)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private func backgroundControls(_ inst: NodeInstance) -> some View {
        scalarSlider(inst, name: "paddingPx", label: "Padding", range: 0...200)
        scalarSlider(inst, name: "cornerRadiusPx", label: "Corner radius", range: 0...80)
        scalarSlider(inst, name: "shadowRadiusPx", label: "Shadow blur", range: 0...100)
        scalarSlider(inst, name: "shadowOpacity", label: "Shadow strength", range: 0...1)

        // Style picker (linear / radial / mesh).
        let curStyle = Int(inst.bindings["bgStyle"]?.constantScalar ?? 0)
        HStack(spacing: 6) {
            ForEach([(0, "Linear"), (1, "Radial"), (2, "Mesh")], id: \.0) { (v, label) in
                Button(action: {
                    state.updateNodeBinding(
                        instanceID: inst.instanceID,
                        paramName: "bgStyle",
                        .constant(.scalar(Double(v)))
                    )
                }) {
                    Text(label)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            curStyle == v
                                ? Color.accentColor.opacity(0.65)
                                : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
            }
        }

        colorRow(inst, name: "bgTop", label: "Top color")
        colorRow(inst, name: "bgBottom", label: "Bottom color")

        Text("Presets").font(.caption).foregroundStyle(.secondary)
        let cols = [GridItem(.adaptive(minimum: 30), spacing: 6)]
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(BackgroundPreset.all, id: \.name) { p in
                Button(action: { applyPreset(inst, p) }) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [Color(p.top.toNSColor()), Color(p.bottom.toNSColor())],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(p.name)
            }
        }
    }

    // MARK: - Zoom

    @ViewBuilder
    private func zoomControls(_ inst: NodeInstance) -> some View {
        if case .eventDriven(var ed) = inst.bindings["scale"] ?? .constant(.scalar(1)) {
            HStack {
                Text("Peak zoom")
                Spacer()
                Text(String(format: "%.2f×", ed.peak.asScalar ?? 1))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { ed.peak.asScalar ?? 1 },
                    set: { v in
                        ed.peak = .scalar(v)
                        state.updateNodeBinding(
                            instanceID: inst.instanceID,
                            paramName: "scale",
                            .eventDriven(ed)
                        )
                    }
                ),
                in: 1.0...2.5
            )
            HStack {
                Text("Hold")
                Spacer()
                Text(String(format: "%.1fs", ed.envelope.hold))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { ed.envelope.hold },
                    set: { v in
                        ed.envelope = Envelope(
                            attack: ed.envelope.attack, hold: v,
                            release: ed.envelope.release, ease: ed.envelope.ease
                        )
                        state.updateNodeBinding(
                            instanceID: inst.instanceID,
                            paramName: "scale",
                            .eventDriven(ed)
                        )
                    }
                ),
                in: 0.2...3.0
            )
        } else {
            Text("Manual zoom binding (TODO)").foregroundStyle(.tertiary)
        }
    }

    // MARK: - Cursor / bubble / webcam

    @ViewBuilder
    private func cursorControls(_ inst: NodeInstance) -> some View {
        scalarSlider(inst, name: "scale", label: "Cursor size", range: 1.0...4.0)
        scalarSlider(inst, name: "highlightAlpha", label: "Halo strength", range: 0...1)
        scalarSlider(inst, name: "highlightRadius", label: "Halo size", range: 8...80)
    }

    @ViewBuilder
    private func bubbleControls(_ inst: NodeInstance) -> some View {
        scalarSlider(inst, name: "maxRadiusPx", label: "Bubble size", range: 40...300)
    }

    @ViewBuilder
    private func captionControls(_ inst: NodeInstance) -> some View {
        if state.project.captions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No captions yet. Generate from your microphone audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: { state.generateCaptions() }) {
                    HStack(spacing: 6) {
                        if state.isTranscribing {
                            ProgressView().controlSize(.small)
                            Text("Transcribing…")
                        } else {
                            Image(systemName: "waveform.and.mic")
                            Text("Generate Captions")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isTranscribing)
            }
        } else {
            HStack {
                Text("\(state.project.captions.count) captions").font(.caption)
                Spacer()
                Button(action: { state.generateCaptions() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Regenerate")
                .disabled(state.isTranscribing)
            }
            scalarSlider(inst, name: "fontSize", label: "Font size", range: 24...96)
            scalarSlider(inst, name: "marginPx", label: "Bottom margin", range: 40...300)
        }
        if let err = state.transcribeError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func webcamControls(_ inst: NodeInstance) -> some View {
        scalarSlider(inst, name: "sizePx", label: "Webcam size", range: 120...420)
        scalarSlider(inst, name: "marginPx", label: "Margin", range: 0...160)
        // Corner picker.
        let cornerVal = (inst.bindings["corner"]?.constantScalar ?? 3)
        HStack(spacing: 8) {
            Text("Corner").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach([(0, "↖"), (1, "↗"), (2, "↙"), (3, "↘")], id: \.0) { (idx, label) in
                Button(action: {
                    state.updateNodeBinding(
                        instanceID: inst.instanceID,
                        paramName: "corner",
                        .constant(.scalar(Double(idx)))
                    )
                }) {
                    Text(label)
                        .font(.title3)
                        .frame(width: 28, height: 28)
                        .background(
                            Int(cornerVal) == idx
                                ? Color.accentColor.opacity(0.6)
                                : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: - shared helpers

    @ViewBuilder
    private func scalarSlider(
        _ inst: NodeInstance, name: String, label: String, range: ClosedRange<Double>
    ) -> some View {
        let cur = inst.bindings[name]?.constantScalar ?? defaultFor(inst, name) ?? range.lowerBound
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.0f", cur))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { cur },
                    set: { v in
                        state.updateNodeBinding(
                            instanceID: inst.instanceID,
                            paramName: name,
                            .constant(.scalar(v))
                        )
                    }
                ),
                in: range
            )
        }
    }

    private func defaultFor(_ inst: NodeInstance, _ name: String) -> Double? {
        // Cheap fallback table; in the long run, NodeRegistry should expose specs to UI.
        switch (inst.nodeType, name) {
        case ("background_compose", "paddingPx"): return 80
        case ("background_compose", "cornerRadiusPx"): return 24
        case ("background_compose", "shadowRadiusPx"): return 40
        case ("background_compose", "shadowOpacity"): return 0.35
        case ("cursor_paint", "scale"): return 2.4
        case ("click_bubble", "maxRadiusPx"): return 180
        case ("webcam_overlay", "sizePx"): return 220
        case ("webcam_overlay", "marginPx"): return 48
        default: return nil
        }
    }

    @ViewBuilder
    private func colorRow(_ inst: NodeInstance, name: String, label: String) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            ColorPicker(
                "",
                selection: Binding(
                    get: {
                        if case .constant(let v) = inst.bindings[name] ?? .constant(.color(r: 0, g: 0, b: 0, a: 1)),
                           case .color(let r, let g, let b, let a) = v {
                            return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
                        }
                        return .black
                    },
                    set: { c in
                        let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .black
                        let pv = ParamValue.color(
                            r: Double(ns.redComponent),
                            g: Double(ns.greenComponent),
                            b: Double(ns.blueComponent),
                            a: Double(ns.alphaComponent)
                        )
                        state.updateNodeBinding(
                            instanceID: inst.instanceID,
                            paramName: name,
                            .constant(pv)
                        )
                    }
                )
            ).labelsHidden()
        }
    }

    private func applyPreset(_ inst: NodeInstance, _ p: BackgroundPreset) {
        state.updateNodeBinding(instanceID: inst.instanceID, paramName: "bgTop", .constant(p.top))
        state.updateNodeBinding(instanceID: inst.instanceID, paramName: "bgBottom", .constant(p.bottom))
    }
}

// Convenience extracts on ParamBinding for common UI shapes.
extension ParamBinding {
    var constantScalar: Double? {
        if case .constant(let v) = self, case .scalar(let s) = v { return s }
        return nil
    }
}

extension ParamValue {
    func toNSColor() -> NSColor {
        if case .color(let r, let g, let b, let a) = self {
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        return .black
    }
}

struct BackgroundPreset {
    let name: String
    let top: ParamValue
    let bottom: ParamValue

    static let all: [BackgroundPreset] = [
        .init(name: "Midnight",
              top: .color(r: 0.13, g: 0.18, b: 0.32, a: 1),
              bottom: .color(r: 0.05, g: 0.06, b: 0.10, a: 1)),
        .init(name: "Sunset",
              top: .color(r: 0.99, g: 0.41, b: 0.30, a: 1),
              bottom: .color(r: 0.55, g: 0.13, b: 0.45, a: 1)),
        .init(name: "Forest",
              top: .color(r: 0.10, g: 0.32, b: 0.18, a: 1),
              bottom: .color(r: 0.02, g: 0.10, b: 0.06, a: 1)),
        .init(name: "Cotton",
              top: .color(r: 0.95, g: 0.96, b: 0.98, a: 1),
              bottom: .color(r: 0.78, g: 0.83, b: 0.92, a: 1)),
        .init(name: "Pumpkin",
              top: .color(r: 1.00, g: 0.65, b: 0.35, a: 1),
              bottom: .color(r: 0.80, g: 0.30, b: 0.20, a: 1)),
        .init(name: "Ocean",
              top: .color(r: 0.10, g: 0.50, b: 0.90, a: 1),
              bottom: .color(r: 0.02, g: 0.10, b: 0.30, a: 1)),
        .init(name: "Vapor",
              top: .color(r: 0.95, g: 0.55, b: 0.95, a: 1),
              bottom: .color(r: 0.20, g: 0.55, b: 0.95, a: 1)),
        .init(name: "Mint",
              top: .color(r: 0.45, g: 0.95, b: 0.78, a: 1),
              bottom: .color(r: 0.10, g: 0.55, b: 0.50, a: 1)),
        .init(name: "Coral",
              top: .color(r: 1.00, g: 0.55, b: 0.55, a: 1),
              bottom: .color(r: 0.95, g: 0.30, b: 0.45, a: 1)),
        .init(name: "Slate",
              top: .color(r: 0.40, g: 0.45, b: 0.55, a: 1),
              bottom: .color(r: 0.12, g: 0.15, b: 0.20, a: 1)),
        .init(name: "Cream",
              top: .color(r: 0.99, g: 0.93, b: 0.78, a: 1),
              bottom: .color(r: 0.94, g: 0.78, b: 0.55, a: 1)),
        .init(name: "Aurora",
              top: .color(r: 0.30, g: 0.92, b: 0.65, a: 1),
              bottom: .color(r: 0.55, g: 0.22, b: 0.78, a: 1)),
    ]
}
