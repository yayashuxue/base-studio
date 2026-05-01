import BaseStudioCore
import SwiftUI

/// Right-side inspector panel of the editor.
///
/// Studio Console aesthetic: each control group is its own card-like section
/// with an uppercase section header (icon + label, tight tracking), 16pt
/// vertical rhythm between sections, and value displays in a mono font so
/// numbers stay column-aligned. Per-effect controls are auto-built from the
/// node type — adding a new effect is one new `case` in `controls(for:)`.
struct InspectorView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var vm: RecordingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BS.Space.section) {
                canvasSection
                exportSection
                if let regID = state.selectedRegionID,
                   let region = state.project.zoomRegions.first(where: { $0.id == regID }) {
                    selectedRegionSection(region)
                }
                ForEach(state.project.nodeGraph.nodes, id: \.instanceID) { instance in
                    nodeSection(for: instance)
                }
                Spacer(minLength: BS.Space.regular)
            }
            .padding(.horizontal, BS.Space.regular)
            .padding(.top, BS.Space.regular)
            .padding(.bottom, BS.Space.section)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: BS.Space.tight - 2) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BS.Color.textTertiary)
            Text(title)
                .bsSectionHeader()
            Spacer()
        }
    }

    // MARK: - Canvas (aspect ratio)

    @ViewBuilder
    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: BS.Space.snug) {
            sectionHeader("Canvas", icon: "rectangle.dashed")
            HStack(spacing: BS.Space.tight) {
                ForEach(CanvasSpec.presets, id: \.self) { preset in
                    canvasTile(preset)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func canvasTile(_ preset: CanvasSpec) -> some View {
        let isOn = state.project.canvas == preset
        let w: CGFloat = 26 * CGFloat(preset.widthPx) / CGFloat(max(preset.widthPx, preset.heightPx))
        let h: CGFloat = 26 * CGFloat(preset.heightPx) / CGFloat(max(preset.widthPx, preset.heightPx))
        return Button(action: { state.setCanvas(preset) }) {
            VStack(spacing: BS.Space.micro) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? BS.Color.accent : BS.Color.textTertiary.opacity(0.6))
                    .frame(width: w, height: h)
                    .frame(width: 26, height: 26)
                Text(preset.label)
                    .font(BS.Font.caption)
                    .foregroundStyle(isOn ? BS.Color.textPrimary : BS.Color.textSecondary)
            }
            .frame(width: 54, height: 50)
            .bsSelectableTile(isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: BS.Space.snug) {
            sectionHeader("Export", icon: "square.and.arrow.up")

            HStack(spacing: BS.Space.micro + 2) {
                ForEach(RecordingViewModel.ExportResolution.allCases) { res in
                    segmentedButton(
                        text: res.label,
                        isOn: vm.exportResolution == res,
                        action: { vm.exportResolution = res }
                    )
                }
            }

            HStack {
                Text(targetDimsLabel)
                    .font(BS.Font.mono)
                    .foregroundStyle(BS.Color.textSecondary)
                Spacer()
                Text("≈\(estimatedBitrateMbps) Mbps")
                    .font(BS.Font.mono)
                    .foregroundStyle(BS.Color.textTertiary)
            }

            Text("Audio")
                .font(BS.Font.caption)
                .foregroundStyle(BS.Color.textTertiary)
                .padding(.top, BS.Space.micro)
            HStack(spacing: BS.Space.micro + 2) {
                ForEach(RecordingViewModel.ExportAudio.allCases) { mode in
                    Button(action: { vm.exportAudio = mode }) {
                        VStack(spacing: 2) {
                            Image(systemName: mode.icon).font(.system(size: 11))
                            Text(mode.label).font(BS.Font.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(vm.exportAudio == mode ? BS.Color.textPrimary : BS.Color.textSecondary)
                        .bsSelectableTile(isOn: vm.exportAudio == mode)
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

    // MARK: - Selected zoom region

    @ViewBuilder
    private func selectedRegionSection(_ region: ZoomRegion) -> some View {
        VStack(alignment: .leading, spacing: BS.Space.snug) {
            HStack(spacing: BS.Space.tight - 2) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BS.Color.textTertiary)
                Text("Zoom Region")
                    .bsSectionHeader()
                Spacer()
                Button(action: { state.deleteZoomRegion(region.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(BS.Color.recordingRed.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Delete region")
            }

            valueRow(label: "Scale", value: String(format: "%.2f×", region.scale))
            HStack(spacing: BS.Space.micro + 2) {
                ForEach([1.2, 1.4, 1.6, 1.8, 2.0, 2.5], id: \.self) { v in
                    segmentedButton(
                        text: String(format: "%.1f×", v),
                        isOn: abs(region.scale - v) < 0.05,
                        action: { state.updateZoomRegion(region.id) { $0.scale = v } }
                    )
                }
            }

            Toggle(isOn: Binding(
                get: { region.followCursor },
                set: { v in state.updateZoomRegion(region.id) { $0.followCursor = v } }
            )) {
                Text("Follow cursor")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(BS.Color.accent)

            valueRow(label: "Speed", value: String(format: "%.1f×", region.speed))
            HStack(spacing: BS.Space.micro + 2) {
                ForEach([1.0, 1.2, 1.4, 1.6, 1.8, 2.0], id: \.self) { v in
                    segmentedButton(
                        text: v == 1.0 ? "1×" : String(format: "%.1f×", v),
                        isOn: abs(region.speed - v) < 0.05,
                        action: { state.updateZoomRegion(region.id) { $0.speed = v } }
                    )
                }
            }

            valueRow(label: "Transition", value: String(format: "%.2fs", region.transitionSec))
            Slider(
                value: Binding(
                    get: { region.transitionSec },
                    set: { v in state.updateZoomRegion(region.id) { $0.transitionSec = v } }
                ),
                in: 0.05...1.5
            )
            .tint(BS.Color.accent)
        }
    }

    // MARK: - Per-node sections

    @ViewBuilder
    private func nodeSection(for inst: NodeInstance) -> some View {
        VStack(alignment: .leading, spacing: BS.Space.snug) {
            HStack(spacing: BS.Space.tight - 2) {
                Image(systemName: nodeIcon(for: inst.nodeType))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BS.Color.textTertiary)
                Text(displayName(for: inst.nodeType))
                    .bsSectionHeader()
                Spacer()
                Toggle("", isOn: Binding(
                    get: { inst.enabled },
                    set: { state.setNodeEnabled(instanceID: inst.instanceID, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(BS.Color.accent)
            }
            controls(for: inst)
                .opacity(inst.enabled ? 1 : 0.45)
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

    private func nodeIcon(for id: String) -> String {
        switch id {
        case "background_compose": return "square.fill.on.square.fill"
        case "zoom": return "plus.magnifyingglass"
        case "cursor_paint": return "cursorarrow"
        case "click_bubble": return "circle.dotted"
        case "webcam_overlay": return "person.crop.circle.fill"
        case "caption_overlay": return "captions.bubble"
        default: return "slider.horizontal.3"
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
            Text("(no editor)")
                .font(BS.Font.caption)
                .foregroundStyle(BS.Color.textTertiary)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private func backgroundControls(_ inst: NodeInstance) -> some View {
        scalarSlider(inst, name: "paddingPx", label: "Padding", range: 0...200)
        scalarSlider(inst, name: "cornerRadiusPx", label: "Corner radius", range: 0...80)
        scalarSlider(inst, name: "shadowRadiusPx", label: "Shadow blur", range: 0...100)
        scalarSlider(inst, name: "shadowOpacity", label: "Shadow strength", range: 0...1)

        let curStyle = Int(inst.bindings["bgStyle"]?.constantScalar ?? 0)
        HStack(spacing: BS.Space.micro + 2) {
            ForEach([(0, "Linear"), (1, "Radial"), (2, "Mesh")], id: \.0) { (v, label) in
                segmentedButton(
                    text: label,
                    isOn: curStyle == v,
                    action: {
                        state.updateNodeBinding(
                            instanceID: inst.instanceID,
                            paramName: "bgStyle",
                            .constant(.scalar(Double(v)))
                        )
                    }
                )
            }
        }

        colorRow(inst, name: "bgTop", label: "Top color")
        colorRow(inst, name: "bgBottom", label: "Bottom color")

        Text("Presets")
            .font(BS.Font.caption)
            .foregroundStyle(BS.Color.textTertiary)
            .padding(.top, BS.Space.micro)
        let cols = [GridItem(.adaptive(minimum: 32), spacing: BS.Space.tight - 2)]
        LazyVGrid(columns: cols, spacing: BS.Space.tight - 2) {
            ForEach(BackgroundPreset.all, id: \.name) { p in
                Button(action: { applyPreset(inst, p) }) {
                    RoundedRectangle(cornerRadius: BS.Radius.chip - 2, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(p.top.toNSColor()), Color(p.bottom.toNSColor())],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: BS.Radius.chip - 2, style: .continuous)
                                .strokeBorder(BS.Color.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(p.name)
            }
        }
    }

    // MARK: - Zoom (manual + event-driven)

    @ViewBuilder
    private func zoomControls(_ inst: NodeInstance) -> some View {
        let scaleBinding = inst.bindings["scale"] ?? .constant(.scalar(1))
        if case .eventDriven(var ed) = scaleBinding {
            valueRow(
                label: "Peak zoom",
                value: String(format: "%.2f×", ed.peak.asScalar ?? 1)
            )
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
            .tint(BS.Color.accent)

            valueRow(
                label: "Hold",
                value: String(format: "%.1fs", ed.envelope.hold)
            )
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
            .tint(BS.Color.accent)
        } else {
            // Manual zoom (constant scalar). Show a slider so the user can
            // tune the global multiplier; auto-zoom regions still bind
            // .eventDriven on top of this.
            let cur = scaleBinding.constantScalar ?? 1.0
            valueRow(label: "Manual zoom", value: String(format: "%.2f×", cur))
            Slider(
                value: Binding(
                    get: { cur },
                    set: { v in
                        state.updateNodeBinding(
                            instanceID: inst.instanceID,
                            paramName: "scale",
                            .constant(.scalar(v))
                        )
                    }
                ),
                in: 1.0...2.5
            )
            .tint(BS.Color.accent)
            Text("Click on the timeline to add a click-driven zoom region.")
                .font(BS.Font.caption)
                .foregroundStyle(BS.Color.textTertiary)
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
            VStack(alignment: .leading, spacing: BS.Space.tight) {
                Text("No captions yet. Generate from your microphone audio.")
                    .font(BS.Font.caption)
                    .foregroundStyle(BS.Color.textSecondary)
                Button(action: { state.generateCaptions() }) {
                    HStack(spacing: BS.Space.tight - 2) {
                        if state.isTranscribing {
                            ProgressView().controlSize(.small)
                            Text("Transcribing…")
                        } else {
                            Image(systemName: "waveform.and.mic")
                            Text("Generate Captions")
                        }
                    }
                    .font(BS.Font.labelStrong)
                    .foregroundStyle(Color(hex: 0x1A1102))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                            .fill(LinearGradient(
                                colors: [BS.Color.accent, BS.Color.accent.opacity(0.82)],
                                startPoint: .top, endPoint: .bottom
                            ))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                            .strokeBorder(BS.Color.topHighlight, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(state.isTranscribing)
            }
        } else {
            HStack {
                Text("\(state.project.captions.count) captions")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.textSecondary)
                Spacer()
                Button(action: { state.generateCaptions() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(BS.Color.textSecondary)
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
                .font(BS.Font.caption)
                .foregroundStyle(BS.Color.recordingRed)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func webcamControls(_ inst: NodeInstance) -> some View {
        scalarSlider(inst, name: "sizePx", label: "Webcam size", range: 120...420)
        scalarSlider(inst, name: "marginPx", label: "Margin", range: 0...160)
        let cornerVal = inst.bindings["corner"]?.constantScalar ?? 3
        HStack(spacing: BS.Space.tight) {
            Text("Corner")
                .font(BS.Font.label)
                .foregroundStyle(BS.Color.textSecondary)
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
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Int(cornerVal) == idx ? BS.Color.textPrimary : BS.Color.textSecondary)
                        .bsSelectableTile(isOn: Int(cornerVal) == idx, radius: BS.Radius.chip - 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shared helpers

    /// Label · monospaced value, in a row.
    private func valueRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(BS.Font.label)
                .foregroundStyle(BS.Color.textSecondary)
            Spacer()
            Text(value)
                .font(BS.Font.mono)
                .foregroundStyle(BS.Color.textPrimary)
        }
    }

    /// Single segmented-style button used in the picker rows.
    private func segmentedButton(text: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(BS.Font.caption)
                .foregroundStyle(isOn ? BS.Color.textPrimary : BS.Color.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 24)
                .bsSelectableTile(isOn: isOn, radius: BS.Radius.chip - 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func scalarSlider(
        _ inst: NodeInstance, name: String, label: String, range: ClosedRange<Double>
    ) -> some View {
        let cur = inst.bindings[name]?.constantScalar ?? defaultFor(inst, name) ?? range.lowerBound
        VStack(alignment: .leading, spacing: BS.Space.micro) {
            valueRow(label: label, value: String(format: "%.0f", cur))
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
            .tint(BS.Color.accent)
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
            Text(label)
                .font(BS.Font.label)
                .foregroundStyle(BS.Color.textSecondary)
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
