import BaseStudioCore
import BaseStudioRecording
import SwiftUI

/// Pre-record landing screen. Big webcam preview, capture options, large Record
/// button, and the recordings library.
struct HomeView: View {
    @ObservedObject var vm: RecordingViewModel
    @ObservedObject var webcamPreview: WebcamPreviewSession

    var body: some View {
        HStack(spacing: 0) {
            RecordingsListView(vm: vm)
            Divider().opacity(0.2)

            VStack(spacing: 24) {
                Spacer().frame(height: 4)
                titleArea
                webcamPreviewArea
                optionsRow
                targetPicker
                recordCTA
                Spacer()
                if vm.library.isEmpty == false {
                    librarySummary
                }
                Spacer().frame(height: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        }
    }

    // MARK: - sections

    private var titleArea: some View {
        VStack(spacing: 6) {
            Text("Base Studio")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("Record your screen, then edit live with auto-zoom, padding, and webcam.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var webcamPreviewArea: some View {
        let size: CGFloat = 220
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: size, height: size)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            if vm.includeWebcam {
                if webcamPreview.permissionDenied {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("Camera permission denied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Enable in System Settings → Privacy")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if webcamPreview.isRunning {
                    WebcamPreviewView(
                        session: webcamPreview.session, mirrored: true,
                        cornerRadius: size / 2
                    )
                    .frame(width: size, height: size)
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Webcam off")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 28) {
            optionCard(
                title: "Webcam", systemImage: "person.crop.circle.fill",
                isOn: $vm.includeWebcam
            )
            optionCard(
                title: "System audio", systemImage: "speaker.wave.2.fill",
                isOn: $vm.includeSystemAudio
            )
            optionCard(
                title: "Microphone", systemImage: "mic.fill",
                isOn: $vm.includeMic
            )
        }
    }

    private func optionCard(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .white.opacity(0.45))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? .white : .white.opacity(0.55))
            }
            .frame(width: 110, height: 70)
            .background(
                isOn.wrappedValue
                    ? Color.accentColor.opacity(0.18)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isOn.wrappedValue
                            ? Color.accentColor.opacity(0.6)
                            : Color.white.opacity(0.08),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var targetPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: targetIcon)
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 12))
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
                            Text(w.label)
                                .tag("w_\(w.id)")
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 320)

            Button(action: { Task { await vm.refreshDisplays() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh windows")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var targetIcon: String {
        switch vm.selectedTarget {
        case .window: return "macwindow"
        case .display, .none: return "display"
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

    private var recordCTA: some View {
        Button(action: vm.startRecording) {
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 12, height: 12)
                Text("Start Recording")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 32).padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(.white)
            .shadow(color: Color.accentColor.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command])
    }

    private var librarySummary: some View {
        Text("\(vm.library.count) recording\(vm.library.count == 1 ? "" : "s") saved · pick from sidebar to edit")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
    }
}
