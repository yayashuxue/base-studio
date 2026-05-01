import AppKit
import BaseStudioCore
import BaseStudioRecording
import SwiftUI

/// Pre-record landing screen.
///
/// Studio Console aesthetic — single-column composition centred on a preview
/// tile of *what will be captured*. Inspired by Cap / Screen Studio: less
/// pre-flight chrome, more "this is what your recording will look like."
///
/// Layout (top → bottom):
///   1. Title + subtitle (left-aligned, no centred-marketing-page vibe).
///   2. Preview tile — display aspect-ratio tile with the webcam circle
///      overlaid in the chosen corner. Mirrors the actual rendered output.
///   3. Source picker chip — sits just below the tile like a caption.
///   4. Pill-row of capture toggles — webcam / system audio / mic.
///   5. Big primary record CTA + keyboard hint.
///   6. Library summary (subtle).
struct HomeView: View {
    @ObservedObject var vm: RecordingViewModel
    @ObservedObject var webcamPreview: WebcamPreviewSession
    @ObservedObject var screenPreview: ScreenPreviewSession

    var body: some View {
        HStack(spacing: 0) {
            RecordingsListView(vm: vm)
            Divider().opacity(0.0) // hairline already provided by RecordingsListView background

            ScrollView {
                VStack(alignment: .leading, spacing: BS.Space.section) {
                    titleArea
                    previewTile
                    sourceCaption
                    optionsPills
                    recordCTA
                    Spacer(minLength: BS.Space.regular)
                    if vm.library.isEmpty == false {
                        librarySummary
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, BS.Space.xl)
                .padding(.top, BS.Space.xl)
                .padding(.bottom, BS.Space.section)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Title

    private var titleArea: some View {
        HStack(alignment: .center, spacing: BS.Space.snug) {
            // 2pt amber accent rule — "lit" indicator next to the title.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(BS.Color.accent)
                .frame(width: 3, height: 36)
                .shadow(color: BS.Color.accent.opacity(0.5), radius: 6, x: 0, y: 0)
            VStack(alignment: .leading, spacing: BS.Space.micro) {
                Text("Base Studio")
                    .font(BS.Font.display)
                    .foregroundStyle(BS.Color.textPrimary)
                Text("Record your screen, then edit live with auto-zoom, padding, and webcam.")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Preview tile (display aspect-ratio + webcam overlay)

    private var previewTile: some View {
        // Aspect ratio of the selected display (or sane default 16:9).
        let aspect = currentAspect
        return ZStack(alignment: webcamCornerAlignment) {
            // Tile background — soft graphite gradient, hairline border.
            RoundedRectangle(cornerRadius: BS.Radius.panel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [BS.Color.surfaceLit, BS.Color.surfaceRaised],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BS.Radius.panel, style: .continuous)
                        .strokeBorder(BS.Color.topHighlightGradient, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BS.Radius.panel, style: .continuous)
                        .strokeBorder(BS.Color.hairline, lineWidth: 1)
                )

            // Live screen thumbnail — actual content of what will be
            // captured. Updates ~1.2× / sec from `ScreenPreviewSession`.
            // While we're waiting for the first frame, fall back to the
            // glyph + label placeholder so the tile never reads empty.
            if let img = screenPreview.currentImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .clipped()
                    .clipShape(RoundedRectangle(
                        cornerRadius: BS.Radius.panel, style: .continuous))
            } else {
                // Soft radial vignette — gives the tile a cinema-like centre
                // glow while the first frame is in flight.
                RadialGradient(
                    colors: [BS.Color.accent.opacity(0.07), .clear],
                    center: .center, startRadius: 0, endRadius: 280
                )

                VStack(spacing: BS.Space.snug) {
                    Image(systemName: targetGlyph)
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(BS.Color.textSecondary)
                    Text(targetTitle)
                        .font(BS.Font.labelStrong)
                        .foregroundStyle(BS.Color.textPrimary)
                    Text(targetSubtitle)
                        .font(BS.Font.mono)
                        .foregroundStyle(BS.Color.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Webcam overlay — a small circle in the corner, like Screen Studio.
            if vm.includeWebcam {
                webcamOverlay
                    .padding(BS.Space.regular)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var currentAspect: CGFloat {
        switch vm.selectedTarget {
        case .display(let id):
            if let d = vm.displays.first(where: { $0.id == id }) {
                return CGFloat(d.widthPx) / CGFloat(d.heightPx)
            }
        case .window(let id):
            if let w = vm.windows.first(where: { $0.id == id }), w.widthPx > 0, w.heightPx > 0 {
                return CGFloat(w.widthPx) / CGFloat(w.heightPx)
            }
        case .none:
            break
        }
        return 16.0 / 9.0
    }

    private var targetGlyph: String {
        switch vm.selectedTarget {
        case .window: return "macwindow"
        case .display, .none: return "display"
        }
    }
    private var targetTitle: String {
        switch vm.selectedTarget {
        case .display(let id):
            if let d = vm.displays.first(where: { $0.id == id }) {
                return d.isMain ? "Main Display" : d.label
            }
            return "Display"
        case .window(let id):
            if let w = vm.windows.first(where: { $0.id == id }) { return w.label }
            return "Window"
        case .none: return "Choose source"
        }
    }
    private var targetSubtitle: String {
        switch vm.selectedTarget {
        case .display(let id):
            if let d = vm.displays.first(where: { $0.id == id }) {
                return "\(d.widthPx) × \(d.heightPx)"
            }
        case .window(let id):
            if let w = vm.windows.first(where: { $0.id == id }) {
                return "\(w.widthPx) × \(w.heightPx)"
            }
        case .none: return "—"
        }
        return ""
    }

    // MARK: - Webcam overlay (lives inside the preview tile)

    private var webcamCornerAlignment: Alignment {
        // Mirror Screen Studio's default: bottom-right.
        .bottomTrailing
    }

    @ViewBuilder
    private var webcamOverlay: some View {
        let size: CGFloat = 96
        ZStack {
            Circle()
                .fill(BS.Color.surface)
                .overlay(Circle().stroke(BS.Color.hairline, lineWidth: 1))
            if webcamPreview.permissionDenied {
                webcamDeniedBadge(size: size)
            } else if webcamPreview.isRunning {
                WebcamPreviewView(
                    session: webcamPreview.session, mirrored: true,
                    cornerRadius: size / 2
                )
                .overlay(Circle().stroke(BS.Color.topHighlight, lineWidth: 1))
            } else {
                ProgressView().controlSize(.small).tint(BS.Color.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private func webcamDeniedBadge(size: CGFloat) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(BS.Color.statusWarn)
            Text("Camera")
                .font(BS.Font.caption)
                .foregroundStyle(BS.Color.textSecondary)
            HStack(spacing: 4) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Settings")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(BS.Color.accent)

                Button {
                    Task { await webcamPreview.startIfPossible() }
                } label: {
                    Text("Retry")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(BS.Color.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .padding(2)
    }

    // MARK: - Source caption (target picker as a chip)

    private var sourceCaption: some View {
        HStack(spacing: BS.Space.tight) {
            Image(systemName: targetGlyph)
                .font(.system(size: 11))
                .foregroundStyle(BS.Color.textTertiary)
            Picker("", selection: Binding(
                get: { targetTagFor(vm.selectedTarget) },
                set: { tag in vm.selectedTarget = targetFromTag(tag) }
            )) {
                if !vm.displays.isEmpty {
                    Section("Displays") {
                        ForEach(vm.displays) { d in
                            Text("\(d.isMain ? "Main: " : "")\(d.label) (\(d.widthPx)×\(d.heightPx))")
                                .tag("d_\(d.id)")
                        }
                    }
                }
                if !vm.windows.isEmpty {
                    Section("Windows") {
                        ForEach(vm.windows) { w in
                            Text(w.label).tag("w_\(w.id)")
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .tint(BS.Color.textSecondary)
            .frame(maxWidth: 320)

            Button(action: { Task { await vm.refreshDisplays() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(BS.Color.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh windows")
            Spacer()
        }
    }

    private func targetTagFor(_ t: CaptureTarget?) -> String {
        switch t {
        case .display(let id): return "d_\(id)"
        case .window(let id): return "w_\(id)"
        case .none: return ""
        }
    }
    private func targetFromTag(_ tag: String) -> CaptureTarget? {
        if tag.hasPrefix("d_"), let id = UInt32(tag.dropFirst(2)) { return .display(id) }
        if tag.hasPrefix("w_"), let id = UInt32(tag.dropFirst(2)) { return .window(id) }
        return nil
    }

    // MARK: - Capture options as pill row

    private var optionsPills: some View {
        HStack(spacing: BS.Space.snug) {
            optionPill(
                title: "Webcam", systemImage: "person.crop.circle.fill",
                isOn: $vm.includeWebcam
            )
            optionPill(
                title: "System audio", systemImage: "speaker.wave.2.fill",
                isOn: $vm.includeSystemAudio
            )
            optionPill(
                title: "Microphone", systemImage: "mic.fill",
                isOn: $vm.includeMic
            )
            Spacer()
        }
    }

    private func optionPill(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button(action: { withAnimation(BS.Motion.snap) { isOn.wrappedValue.toggle() } }) {
            HStack(spacing: BS.Space.tight) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(BS.Font.labelStrong)
            }
            .foregroundStyle(isOn.wrappedValue ? BS.Color.textPrimary : BS.Color.textSecondary)
            .padding(.horizontal, BS.Space.regular)
            .padding(.vertical, BS.Space.tight + 2)
            .bsSelectablePill(isOn: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Record CTA

    private var recordCTA: some View {
        HStack(spacing: BS.Space.regular) {
            Button(action: vm.startRecording) {
                HStack(spacing: BS.Space.snug) {
                    Circle()
                        .fill(BS.Color.recordingRed)
                        .frame(width: 10, height: 10)
                    Text("Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, BS.Space.section)
                .padding(.vertical, BS.Space.snug + 2)
                .background(
                    BS.Color.accentGradient,
                    in: RoundedRectangle(cornerRadius: BS.Radius.card, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BS.Radius.card, style: .continuous)
                        .strokeBorder(BS.Color.topHighlight, lineWidth: 1)
                )
                .foregroundStyle(BS.Color.onAccent)
                .shadow(color: BS.Color.accent.opacity(0.35), radius: 18, x: 0, y: 6)
                .opacity(vm.canStartRecording ? 1.0 : 0.45)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            // Disable while a recording is already in flight (countdown /
            // recording / finalizing). Without this, rapid double-clicks or
            // a held ⌘R fire startRecording multiple times.
            .disabled(!vm.canStartRecording)

            Text("⌘R")
                .font(BS.Font.mono)
                .foregroundStyle(BS.Color.textTertiary)
        }
    }

    // MARK: - Library summary

    private var librarySummary: some View {
        HStack(spacing: BS.Space.tight) {
            Image(systemName: "tray.full")
                .font(.system(size: 10))
                .foregroundStyle(BS.Color.textTertiary)
            Text("\(vm.library.count) recording\(vm.library.count == 1 ? "" : "s") saved · pick from sidebar to edit")
                .font(BS.Font.caption)
                .foregroundStyle(BS.Color.textTertiary)
        }
    }
}
