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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = RecordingViewModel()
    @StateObject private var webcamPreview = WebcamPreviewSession()
    @StateObject private var screenPreview = ScreenPreviewSession()

    var body: some View {
        ZStack {
            BS.Color.bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                BSHairline()
                if let editor = vm.editorState {
                    editorPane(editor)
                } else if case .failed(let message) = vm.phase, let bundle = vm.lastBundle {
                    BrokenBundleCard(
                        bundle: bundle,
                        message: message,
                        onReveal: vm.revealLastBundle,
                        onDelete: vm.deleteLastBundle
                    )
                } else {
                    welcomePane
                }
                if vm.exportPhase != .none {
                    BSHairline()
                    exportBar.padding(BS.Space.snug)
                        .background(BS.Color.surface)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.webcamPreview = webcamPreview
            vm.showWebcamPreview = true
            if shouldRunWebcamPreview {
                Task { await webcamPreview.startIfPossible() }
            }
            screenPreview.setTarget(vm.selectedTarget)
            if shouldRunScreenPreview {
                screenPreview.start()
            }
        }
        .onDisappear {
            vm.showWebcamPreview = false
            webcamPreview.stop()
            screenPreview.stop()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                vm.showWebcamPreview = true
            case .background:
                vm.showWebcamPreview = false
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: shouldRunWebcamPreview) { run in
            Task {
                if run { await webcamPreview.startIfPossible() }
                else { webcamPreview.stop() }
            }
        }
        .onChange(of: vm.selectedTarget) { newTarget in
            screenPreview.setTarget(newTarget)
            if shouldRunScreenPreview {
                screenPreview.start()
            } else {
                screenPreview.stop()
            }
        }
        .onChange(of: shouldRunScreenPreview) { run in
            if run { screenPreview.start() } else { screenPreview.stop() }
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

    private var homeButton: some View {
        Button(action: {
            vm.editorState = nil
            screenPreview.start()
        }) {
            HStack(spacing: BS.Space.gap) {
                Image(systemName: "house.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("Home")
                    .font(BS.Font.labelStrong)
            }
            .foregroundStyle(BS.Color.textPrimary)
            .padding(.horizontal, BS.Space.snug)
            .padding(.vertical, BS.Space.gap)
            .bsSelectableTile(isOn: false)
        }
        .buttonStyle(.plain)
    }

    private var exportButton: some View {
        Button(action: vm.polishAndExport) {
            HStack(spacing: BS.Space.gap) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                Text("Export")
                    .font(BS.Font.labelStrong)
            }
            .foregroundStyle(BS.Color.onAccent)
            .padding(.horizontal, BS.Space.snug)
            .padding(.vertical, BS.Space.gap)
            .bsAccentButton()
        }
        .buttonStyle(.plain)
        .disabled(isExportingNow)
    }

    /// True only for selected windows on Home, when no recording is in flight.
    /// Full-display live preview creates a black/self-referential tile because
    /// Base Studio itself is covering the display; use the static source card
    /// for display targets instead.
    private var shouldRunScreenPreview: Bool {
        guard vm.editorState == nil else { return false }
        guard case .window = vm.selectedTarget else { return false }
        switch vm.phase {
        case .recording, .finalizing, .countingDown: return false
        case .idle, .done, .failed: return true
        }
    }

    /// True only while the main Home window owns the preview, outside of an
    /// active capture. `includeWebcam` means record the camera track; the
    /// menu-bar-only/hidden app should not keep the camera alive.
    private var shouldRunWebcamPreview: Bool {
        guard vm.includeWebcam else { return false }
        guard vm.showWebcamPreview else { return false }
        guard vm.editorState == nil else { return false }
        switch vm.phase {
        case .recording, .finalizing, .countingDown: return false
        case .idle, .done, .failed: return true
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
            statusChip(label: "Starting…", color: BS.Color.recordingRed) {
                ProgressView().controlSize(.small).tint(BS.Color.recordingRed)
            }
        case .recording:
            statusChip(label: "Recording", color: BS.Color.recordingRed, font: BS.Font.labelStrong) {
                Circle().fill(BS.Color.recordingRed)
                    .frame(width: 8, height: 8)
                    .shadow(color: BS.Color.recordingGlow, radius: 4)
            }
        case .finalizing:
            statusChip(label: "Finalizing…", color: BS.Color.textSecondary) {
                ProgressView().controlSize(.small).tint(BS.Color.textSecondary)
            }
        case .done:
            statusChip(label: "Ready to edit", color: BS.Color.statusOk) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BS.Color.statusOk)
            }
        case .failed(let message):
            if isPermissionFailure(message) {
                HStack(spacing: BS.Space.tight) {
                    statusChip(label: "Permission needed", color: BS.Color.statusWarn) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(BS.Color.statusWarn)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor(for: message))") {
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
            } else {
                statusChip(label: "Couldn't open recording", color: BS.Color.statusWarn) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BS.Color.statusWarn)
                }
            }
        }
    }

    private func isPermissionFailure(_ message: String) -> Bool {
        message.contains("permission")
            || message.contains("Privacy")
            || message.contains("relaunch")
    }

    private func settingsAnchor(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("camera") || lower.contains("webcam") {
            return "Privacy_Camera"
        }
        if lower.contains("microphone") || lower.contains("mic ") || lower.contains("audio") {
            return "Privacy_Microphone"
        }
        return "Privacy_ScreenCapture"
    }

    /// Shared `[leading icon · label]` chip used by the compact top-bar states.
    @ViewBuilder
    private func statusChip<Leading: View>(
        label: String,
        color: Color,
        font: Font = BS.Font.label,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: BS.Space.gap) {
            leading()
            Text(label).font(font).foregroundStyle(color)
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
        HomeView(vm: vm, webcamPreview: webcamPreview, screenPreview: screenPreview)
    }

    @ViewBuilder
    private func editorPane(_ editor: EditorState) -> some View {
        HStack(spacing: 0) {
            RecordingsListView(vm: vm)
            BSHairline(axis: .vertical)

            VStack(spacing: 0) {
                EngineCanvasView(state: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BSHairline()
                VStack(spacing: BS.Space.tight) {
                    ScrubberView(state: editor)
                    TimelineView(state: editor)
                        .padding(.horizontal, BS.Space.micro)
                }
                .padding(.horizontal, BS.Space.regular)
                .padding(.vertical, BS.Space.snug)
                .background(BS.Color.surface.opacity(0.55))
            }

            BSHairline(axis: .vertical)

            InspectorView(state: editor, vm: vm)
                .frame(width: 300)
                .background(BS.Color.surface.opacity(0.65))
        }
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
