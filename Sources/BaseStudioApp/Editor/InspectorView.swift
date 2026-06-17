import AppKit
import BaseStudioCore
import BaseStudioRender
import SwiftUI
import UniformTypeIdentifiers

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

    /// `icon · UPPERCASE TITLE · spacer · optional trailing accessory` row.
    /// Drives every inspector section header.
    private func sectionHeader<Trailing: View>(
        _ title: String,
        icon: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: BS.Space.gap) {
            Image(systemName: icon)
                .font(BS.Font.sectionIcon)
                .foregroundStyle(BS.Color.textTertiary)
            Text(title)
                .bsSectionHeader()
            Spacer()
            trailing()
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

            HStack(spacing: BS.Space.gap) {
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
            HStack(spacing: BS.Space.gap) {
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
            sectionHeader("Zoom Region", icon: "scope") {
                Button(action: { state.deleteZoomRegion(region.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(BS.Color.recordingRed.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Delete region")
            }

            valueRow(label: "Scale", value: String(format: "%.2f×", region.scale))
            HStack(spacing: BS.Space.gap) {
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
            HStack(spacing: BS.Space.gap) {
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
            sectionHeader(displayName(for: inst.nodeType), icon: nodeIcon(for: inst.nodeType)) {
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
        // Image uploads live in a global library so they show up across
        // recordings, not just this one. Path: ~/Library/Application
        // Support/BaseStudio/Backgrounds/.
        let bgImage = state.project.backgroundImageRel
        let curTop = inst.bindings["bgTop"]?.constantValue
        let uploads = BackgroundImageStore.list()
        let cols = [GridItem(.adaptive(minimum: 56), spacing: BS.Space.tight)]
        LazyVGrid(columns: cols, spacing: BS.Space.tight) {
            ForEach(BackgroundPreset.all, id: \.name) { p in
                Button(action: { applyPreset(inst, p) }) {
                    bgTile(selected: bgImage == nil && curTop == p.top) {
                        tileShape().fill(presetTileFill(p))
                    }
                }
                .buttonStyle(.plain)
                .help(p.name)
            }
            ForEach(uploads, id: \.self) { name in
                Button(action: { state.selectBackgroundImage(name) }) {
                    bgTile(selected: bgImage == name) {
                        if let preview = uploadedThumbnail(name) {
                            Image(nsImage: preview)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(tileShape())
                        } else {
                            tileShape().fill(BS.Color.hairline)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(name)
            }
            Button(action: pickBackgroundImage) {
                bgTile(selected: false) {
                    tileShape()
                        .fill(BS.Color.divider)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(BS.Color.textTertiary)
                        )
                }
            }
            .buttonStyle(.plain)
            .help("Upload an image")
        }
    }

    private func tileShape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: BS.Radius.chip - 2, style: .continuous)
    }

    /// Uniform 48pt tile chrome: shared frame size + selection ring. Children
    /// supply the fill (gradient, image, or "+").
    @ViewBuilder
    private func bgTile<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .overlay(
                tileShape()
                    .strokeBorder(selected ? BS.Color.accent : BS.Color.hairline,
                                  lineWidth: selected ? 1.5 : 1)
            )
    }

    /// 64×48 thumbnail of an uploaded background, loaded once per filename.
    /// SwiftUI re-evaluates `body` on every state tick, so without memoising
    /// we'd hit `NSImage(contentsOf:)` for every uploaded tile per render.
    private func uploadedThumbnail(_ name: String) -> NSImage? {
        if let cached = Self.thumbnailCache[name] { return cached }
        guard let url = BackgroundImageStore.url(for: name),
              let img = NSImage(contentsOf: url) else { return nil }
        // Force-rasterise to a small bitmap so SwiftUI doesn't keep a 12MP
        // representation alive per tile.
        let target = NSSize(width: 96, height: 72)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        Self.thumbnailCache[name] = thumb
        return thumb
    }
    private static var thumbnailCache: [String: NSImage] = [:]

    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as background"
        panel.message = "Pick a PNG, JPG, HEIC, or WebP image."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.uploadBackgroundImage(from: url)
        } catch {
            // Surface in the renderFailureMessage banner — there's no other
            // chrome on this surface and a silent failure on a click is
            // worse than a one-line note above the canvas.
            state.renderFailureMessage = "Couldn't import background: \(error.localizedDescription)"
        }
    }

    /// Mirror `BackgroundCompose`'s style in the tile so the picker is WYSIWYG —
    /// linear → vertical stripe, radial → soft glow, mesh → diagonal blend.
    private func presetTileFill(_ p: BackgroundPreset) -> AnyShapeStyle {
        let top = Color(p.top.toNSColor())
        let bottom = Color(p.bottom.toNSColor())
        switch p.style {
        case 1:
            return AnyShapeStyle(RadialGradient(
                colors: [top, bottom],
                center: .center, startRadius: 0, endRadius: 36))
        case 2:
            return AnyShapeStyle(LinearGradient(
                colors: [top, bottom],
                startPoint: .bottomLeading, endPoint: .topTrailing))
        default:
            return AnyShapeStyle(LinearGradient(
                colors: [top, bottom],
                startPoint: .top, endPoint: .bottom))
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
                    HStack(spacing: BS.Space.gap) {
                        if state.isTranscribing {
                            ProgressView().controlSize(.small)
                            Text("Transcribing…")
                        } else {
                            Image(systemName: "waveform.and.mic")
                            Text("Generate Captions")
                        }
                    }
                    .font(BS.Font.labelStrong)
                    .foregroundStyle(BS.Color.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .bsAccentButton()
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
        case ("webcam_overlay", "marginPx"): return 80
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
        // Clicking a gradient implicitly clears any uploaded image —
        // otherwise the image would still paint and the gradient change
        // would look like it did nothing.
        state.clearBackgroundImage()
        state.updateNodeBinding(instanceID: inst.instanceID, paramName: "bgTop", .constant(p.top))
        state.updateNodeBinding(instanceID: inst.instanceID, paramName: "bgBottom", .constant(p.bottom))
        state.updateNodeBinding(instanceID: inst.instanceID, paramName: "bgStyle",
                                .constant(.scalar(Double(p.style))))
    }
}

// Convenience extracts on ParamBinding for common UI shapes.
extension ParamBinding {
    var constantScalar: Double? {
        if case .constant(let v) = self, case .scalar(let s) = v { return s }
        return nil
    }
    var constantValue: ParamValue? {
        if case .constant(let v) = self { return v }
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
    /// Matches `BackgroundCompose.bgStyle`: 0 = linear, 1 = radial, 2 = mesh.
    /// Each preset picks the style that flatters its palette so the rendered
    /// canvas matches the tile and feels distinctive instead of "two flat
    /// blocks of color".
    let style: Int

    /// Five hand-picked presets covering the common moods (dark, warm, light,
    /// cool, vibrant). Kept short on purpose — Screen Studio / CleanShot ship
    /// roughly this many. More palette = decision fatigue, not more taste.
    static let all: [BackgroundPreset] = [
        // Desaturated mid-tones — these read as "designer", not "color picker".
        .init(name: "Midnight",
              top: .color(r: 0.18, g: 0.21, b: 0.30, a: 1),
              bottom: .color(r: 0.06, g: 0.07, b: 0.11, a: 1),
              style: 1),
        .init(name: "Dusk",
              top: .color(r: 0.92, g: 0.55, b: 0.48, a: 1),
              bottom: .color(r: 0.36, g: 0.20, b: 0.42, a: 1),
              style: 2),
        .init(name: "Linen",
              top: .color(r: 0.96, g: 0.95, b: 0.92, a: 1),
              bottom: .color(r: 0.84, g: 0.82, b: 0.78, a: 1),
              style: 0),
        .init(name: "Tide",
              top: .color(r: 0.30, g: 0.55, b: 0.78, a: 1),
              bottom: .color(r: 0.08, g: 0.18, b: 0.32, a: 1),
              style: 1),
        .init(name: "Sage",
              top: .color(r: 0.55, g: 0.72, b: 0.62, a: 1),
              bottom: .color(r: 0.18, g: 0.32, b: 0.30, a: 1),
              style: 2),
    ]
}
