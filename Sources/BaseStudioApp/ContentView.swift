import BaseStudioCore
import BaseStudioPlayback
import SwiftUI

/// Application shell.
///
/// Three modes share the same chrome:
///  - **Home** — pre-record landing (HomeView).
///  - **Editor** — recordings list · canvas + scrubber + timeline · inspector.
///  - **Export bar** — slides up from the bottom while/after exporting.
struct ContentView: View {
    @StateObject private var vm = RecordingViewModel()
    @StateObject private var webcamPreview = WebcamPreviewSession()

    var body: some View {
        ZStack {
            BS.Color.bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                hairline
                if let editor = vm.editorState {
                    editorPane(editor)
                } else {
                    welcomePane
                }
                if vm.exportPhase != .none {
                    hairline
                    exportBar.padding(BS.Space.snug)
                        .background(BS.Color.surface)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.webcamPreview = webcamPreview
            // `.onChange` doesn't fire on initial value, so honour the
            // current `includeWebcam` default explicitly on first appear.
            if vm.includeWebcam {
                Task { await webcamPreview.startIfPossible() }
            }
        }
        .onChange(of: vm.includeWebcam) { newValue in
            Task {
                if newValue { await webcamPreview.startIfPossible() }
                else { webcamPreview.stop() }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: BS.Space.snug) {
            if vm.editorState != nil {
                homeButton
                Divider().frame(height: 18).overlay(BS.Color.divider)
                exportButton
            } else {
                Text(vm.phase == .recording ? "Recording…" : "")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.textSecondary)
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, BS.Space.regular)
        .padding(.vertical, BS.Space.tight + 2)
        .background(BS.Color.surface.opacity(0.6))
        .background(.ultraThinMaterial)
    }

    private var hairline: some View {
        Rectangle().fill(BS.Color.hairline).frame(height: 1)
    }

    private var homeButton: some View {
        Button(action: { vm.editorState = nil }) {
            HStack(spacing: BS.Space.tight - 2) {
                Image(systemName: "house.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("Home")
                    .font(BS.Font.labelStrong)
            }
            .foregroundStyle(BS.Color.textPrimary)
            .padding(.horizontal, BS.Space.snug)
            .padding(.vertical, BS.Space.tight - 2)
            .background(
                RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                    .fill(BS.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                    .strokeBorder(BS.Color.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var exportButton: some View {
        Button(action: vm.polishAndExport) {
            HStack(spacing: BS.Space.tight - 2) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                Text("Export")
                    .font(BS.Font.labelStrong)
            }
            .foregroundStyle(BS.Color.onAccent)
            .padding(.horizontal, BS.Space.snug)
            .padding(.vertical, BS.Space.tight - 2)
            .background(
                RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                    .fill(BS.Color.accentGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                    .strokeBorder(BS.Color.topHighlight, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExportingNow)
    }

    private var canRecord: Bool {
        switch vm.phase {
        case .idle, .done, .failed: return true
        case .countingDown, .recording, .finalizing: return false
        }
    }
    private var isExportingNow: Bool {
        if case .running = vm.exportPhase { return true }
        return false
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch vm.phase {
        case .idle:
            EmptyView()
        case .countingDown:
            HStack(spacing: BS.Space.tight - 2) {
                ProgressView().controlSize(.small).tint(BS.Color.recordingRed)
                Text("Starting…")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.recordingRed)
            }
        case .recording:
            HStack(spacing: BS.Space.tight - 2) {
                Circle().fill(BS.Color.recordingRed)
                    .frame(width: 8, height: 8)
                    .shadow(color: BS.Color.recordingGlow, radius: 4)
                Text("Recording")
                    .font(BS.Font.labelStrong)
                    .foregroundStyle(BS.Color.recordingRed)
            }
        case .finalizing:
            HStack(spacing: BS.Space.tight - 2) {
                ProgressView().controlSize(.small).tint(BS.Color.textSecondary)
                Text("Finalizing…")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.textSecondary)
            }
        case .done:
            HStack(spacing: BS.Space.tight - 2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BS.Color.statusOk)
                Text("Ready to edit")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.statusOk)
            }
        case .failed(let m):
            HStack(spacing: BS.Space.tight) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(BS.Color.statusWarn)
                Text(m)
                    .font(BS.Font.caption)
                    .foregroundStyle(BS.Color.recordingRed)
                    .lineLimit(2)
                if m.contains("permission") || m.contains("Privacy") || m.contains("relaunch") {
                    let lower = m.lowercased()
                    let anchor: String = {
                        if lower.contains("camera") || lower.contains("webcam") {
                            return "Privacy_Camera"
                        } else if lower.contains("microphone") || lower.contains("mic ") || lower.contains("audio") {
                            return "Privacy_Microphone"
                        } else {
                            return "Privacy_ScreenCapture"
                        }
                    }()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Quit & Relaunch") {
                        relaunchApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func relaunchApp() {
        // Spawn a detached shell helper that waits until our PID exits, then
        // launches a fresh app instance. macOS only refreshes per-process
        // permission state on a clean launch — if we open the new instance
        // before this process is gone, it inherits the stale "denied" state.
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let cmd = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        sleep 0.3
        /usr/bin/open -n "\(bundlePath)"
        """
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", cmd]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Welcome / editor panes

    private var welcomePane: some View {
        HomeView(vm: vm, webcamPreview: webcamPreview)
    }

    @ViewBuilder
    private func editorPane(_ editor: EditorState) -> some View {
        HStack(spacing: 0) {
            RecordingsListView(vm: vm)
            verticalDivider

            // Center column: canvas + scrubber + timeline.
            VStack(spacing: 0) {
                EngineCanvasView(state: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                hairline
                VStack(spacing: BS.Space.tight) {
                    ScrubberView(state: editor)
                    TimelineView(state: editor)
                        .padding(.horizontal, BS.Space.micro)
                }
                .padding(.horizontal, BS.Space.regular)
                .padding(.vertical, BS.Space.snug)
                .background(BS.Color.surface.opacity(0.55))
            }

            verticalDivider

            InspectorView(state: editor, vm: vm)
                .frame(width: 300)
                .background(BS.Color.surface.opacity(0.65))
        }
    }

    private var verticalDivider: some View {
        Rectangle().fill(BS.Color.hairline).frame(width: 1)
    }

    @ViewBuilder
    private var exportBar: some View {
        switch vm.exportPhase {
        case .none:
            EmptyView()
        case .running(let p):
            HStack(spacing: BS.Space.snug) {
                ProgressView(value: p)
                    .tint(BS.Color.accent)
                    .frame(maxWidth: 320)
                Text("\(Int(p * 100))%")
                    .font(BS.Font.mono)
                    .foregroundStyle(BS.Color.textSecondary)
                Spacer()
                Button("Cancel", action: vm.cancelExport)
                    .controlSize(.small)
            }
        case .completed(let url):
            HStack(spacing: BS.Space.tight) {
                Label("Exported: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(BS.Font.label)
                    .foregroundStyle(BS.Color.statusOk)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        case .failed(let msg):
            Label("Export failed: \(msg)", systemImage: "xmark.octagon.fill")
                .font(BS.Font.label)
                .foregroundStyle(BS.Color.recordingRed)
        }
    }
}
