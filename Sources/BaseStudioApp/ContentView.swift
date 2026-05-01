import BaseStudioCore
import BaseStudioPlayback
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = RecordingViewModel()
    @StateObject private var webcamPreview = WebcamPreviewSession()

    var body: some View {
        ZStack {
            // Dark studio backdrop.
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.06)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.2)
                if let editor = vm.editorState {
                    editorPane(editor)
                } else {
                    welcomePane
                }
                if vm.exportPhase != .none {
                    Divider().opacity(0.2)
                    exportBar.padding(12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.webcamPreview = webcamPreview
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
        HStack(spacing: 12) {
            if vm.editorState != nil {
                Button(action: { vm.editorState = nil }) {
                    Label("Home", systemImage: "house.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                Divider().frame(height: 22).opacity(0.3)
                exportButton
            } else {
                Text(vm.phase == .recording ? "Recording…" : "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.35))
    }

    private var recordButton: some View {
        Button(action: vm.startRecording) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("Record")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(canRecord ? Color.white.opacity(0.10) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .disabled(!canRecord)
    }

    private var stopButton: some View {
        Button(action: vm.stopRecording) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                Text("Stop")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(vm.phase == .recording ? Color.red.opacity(0.7) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .disabled(vm.phase != .recording)
    }

    private var webcamToggle: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $vm.includeWebcam) {
                Label("Webcam", systemImage: "person.crop.circle.badge.checkmark")
            }
            .toggleStyle(.checkbox)
            .disabled(!canRecord)

            if vm.includeWebcam {
                webcamPreviewBadge
                    .frame(width: 44, height: 44)
            }

            Toggle(isOn: $vm.includeSystemAudio) {
                Label("System audio", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.checkbox)
            .disabled(!canRecord)

            Toggle(isOn: $vm.includeMic) {
                Label("Mic", systemImage: "mic.fill")
            }
            .toggleStyle(.checkbox)
            .disabled(!canRecord)
        }
    }

    @ViewBuilder
    private var webcamPreviewBadge: some View {
        if webcamPreview.permissionDenied {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if webcamPreview.isRunning {
            WebcamPreviewView(session: webcamPreview.session, mirrored: true, cornerRadius: 22)
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var exportButton: some View {
        Button(action: vm.polishAndExport) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text("Export")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .disabled(isExportingNow)
    }

    private var canRecord: Bool {
        switch vm.phase {
        case .idle, .done, .failed: return true
        case .recording, .finalizing: return false
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
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording").font(.caption)
            }.foregroundStyle(.red)
        case .finalizing:
            Text("Finalizing…").font(.caption).foregroundStyle(.secondary)
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Ready to edit").font(.caption)
            }.foregroundStyle(.green)
        case .failed(let m):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(m).font(.caption).foregroundStyle(.red).lineLimit(3)
                if m.contains("permission") || m.contains("Privacy") || m.contains("relaunch") {
                    // Pick the right Privacy pane for the failing subsystem.
                    // The previous hard-coded `Privacy_ScreenCapture` sent
                    // users to the wrong place when the failure was actually
                    // a camera or microphone permission issue.
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
            Divider().opacity(0.2)

            // Center: canvas + scrubber + timeline.
            VStack(spacing: 0) {
                EngineCanvasView(state: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.2)
                VStack(spacing: 8) {
                    ScrubberView(state: editor)
                    TimelineView(state: editor)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.black.opacity(0.3))
            }

            Divider().opacity(0.2)

            InspectorView(state: editor, vm: vm)
                .frame(width: 280)
                .background(Color.black.opacity(0.4))
        }
    }

    @ViewBuilder
    private var exportBar: some View {
        switch vm.exportPhase {
        case .none:
            EmptyView()
        case .running(let p):
            HStack(spacing: 12) {
                ProgressView(value: p).frame(maxWidth: 320)
                Text("\(Int(p * 100))%").monospacedDigit()
                Spacer()
                Button("Cancel", action: vm.cancelExport)
            }
        case .completed(let url):
            HStack {
                Label("Exported: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        case .failed(let msg):
            Label("Export failed: \(msg)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
