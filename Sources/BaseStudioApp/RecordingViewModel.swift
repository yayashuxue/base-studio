import AppKit
import BaseStudioCore
import BaseStudioRecording
import BaseStudioRender
import Foundation
import SwiftUI

@MainActor
final class RecordingViewModel: ObservableObject, StopHandler, EditorActions {

    var isRecording: Bool { phase == .recording }

    // EditorActions — bridge keyboard shortcuts to the active editor.
    func togglePlayPause() { editorState?.playPause() }
    func deleteSelectedRegion() {
        guard let s = editorState, let id = s.selectedRegionID else { return }
        s.deleteZoomRegion(id)
    }
    func export() { polishAndExport() }
    func undo() { editorState?.undo() }
    func redo() { editorState?.redo() }
    func stepBackward(seconds: Double) {
        guard let s = editorState else { return }
        s.setPlayhead(max(0, s.playheadSec - seconds))
    }
    func stepForward(seconds: Double) {
        guard let s = editorState else { return }
        s.setPlayhead(min(s.timelineDurationSec, s.playheadSec + seconds))
    }
    func gotoStart() { editorState?.setPlayhead(0) }
    func gotoEnd() { editorState?.setPlayhead(editorState?.timelineDurationSec ?? 0) }

    enum Phase: Equatable {
        case idle
        /// 3-second countdown overlay is showing; window has already been
        /// hidden so it isn't captured. The user cannot start a *second*
        /// recording from this state — `canStartRecording` returns false
        /// until we drop back to `.idle` (success or failure).
        case countingDown
        case recording
        case finalizing
        case done(ProjectBundle)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.countingDown, .countingDown),
                 (.recording, .recording),
                 (.finalizing, .finalizing):
                return true
            case (.done(let a), .done(let b)):
                return a.url == b.url
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// True only when no recording is in flight (idle, done, or failed).
    /// Bind the Record CTA's `.disabled` to `!canStartRecording` so the
    /// button can't fire twice during countdown / recording / finalize.
    var canStartRecording: Bool {
        switch phase {
        case .idle, .done, .failed: return true
        case .countingDown, .recording, .finalizing: return false
        }
    }

    enum ExportPhase: Equatable {
        case none
        case running(progress: Double)
        case completed(URL)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var lastBundle: ProjectBundle?
    @Published var exportPhase: ExportPhase = .none
    // Default to capturing every input the user has hardware/permission for —
    // a Screen-Studio style "press record and you have everything you need
    // later" stance. Individual toggles still let the user opt out per
    // recording. Permission failures degrade gracefully (mic/webcam start
    // is wrapped in do/catch in `RecordingSession`).
    @Published var includeWebcam: Bool = true
    @Published var includeSystemAudio: Bool = true
    @Published var includeMic: Bool = true
    // OFF by default. The menu-bar status item (red ● + Stop) and ⌘⇧.
    // global shortcut already cover Stop reliably; the floating panel adds
    // a visual outline that distracts from the recorded screen.
    @Published var showFloatingPanel: Bool = false
    @Published var editorState: EditorState?
    @Published var library: [RecordingsLibrary.Entry] = []
    @Published var displays: [DisplayInfo] = []
    @Published var windows: [WindowInfo] = []
    @Published var selectedTarget: CaptureTarget?

    enum ExportResolution: String, CaseIterable, Identifiable {
        case source, p720, p1080, p1440, k4
        var id: String { rawValue }
        var label: String {
            switch self {
            case .source: return "Source"
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "1440p"
            case .k4: return "4K"
            }
        }
        var heightPx: Int? {
            switch self {
            case .source: return nil
            case .p720: return 720
            case .p1080: return 1080
            case .p1440: return 1440
            case .k4: return 2160
            }
        }
        /// Reasonable default bitrate for this height.
        var defaultBitrate: Int {
            switch self {
            case .source: return 12_000_000
            case .p720: return 5_000_000
            case .p1080: return 10_000_000
            case .p1440: return 18_000_000
            case .k4: return 35_000_000
            }
        }
    }

    @Published var exportResolution: ExportResolution = .p1080

    enum ExportAudio: String, CaseIterable, Identifiable {
        case both, micOnly, systemOnly, mute
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both: return "Both"
            case .micOnly: return "Mic"
            case .systemOnly: return "System"
            case .mute: return "Mute"
            }
        }
        var icon: String {
            switch self {
            case .both: return "waveform"
            case .micOnly: return "mic.fill"
            case .systemOnly: return "speaker.wave.2.fill"
            case .mute: return "speaker.slash.fill"
            }
        }
    }
    @Published var exportAudio: ExportAudio = .both

    weak var webcamPreview: WebcamPreviewSession?

    private var session: Any?
    private var exporter: Any?
    private let menuBar = MenuBarController()
    private let countdown = CountdownOverlay()
    private let recordingPanel = RecordingPanel()
    private var hiddenWindow: NSWindow?

    init() {
        AppDelegate.shared.stopHandler = self
        AppDelegate.shared.editorActions = self
        refreshLibrary()
        Task { await refreshDisplays() }
    }

    func refreshDisplays() async {
        guard #available(macOS 13.0, *) else { return }
        let catalog = (try? await CapturePicker.availableTargets())
            ?? CaptureCatalog()
        await MainActor.run {
            self.displays = catalog.displays
            self.windows = catalog.windows
            if self.selectedTarget == nil,
               let main = catalog.displays.first(where: { $0.isMain }) ?? catalog.displays.first {
                self.selectedTarget = .display(main.id)
            }
        }
    }

    func refreshLibrary() {
        library = (try? RecordingsLibrary.list()) ?? []
    }

    func openRecording(_ entry: RecordingsLibrary.Entry) {
        // Broken bundles (zero-byte screen.mov from a finalize-time encoder
        // crash, missing metadata.json, etc.) — bail before EditorState.load
        // crashes / hangs. We surface a `.failed` phase with reveal/delete
        // affordances rendered by the chrome.
        if !entry.isPlayable {
            self.editorState = nil
            self.lastBundle = entry.bundle
            self.exportPhase = .none
            self.phase = .failed("Recording is incomplete (screen.mov is empty or metadata.json is missing). Reveal in Finder or delete it.")
            return
        }
        do {
            self.editorState = try EditorState.load(bundleURL: entry.id)
            self.lastBundle = entry.bundle
            self.exportPhase = .none
            self.phase = .done(entry.bundle)
        } catch {
            self.phase = .failed("Open failed: \(error.localizedDescription)")
        }
    }

    func deleteRecording(_ entry: RecordingsLibrary.Entry) {
        try? RecordingsLibrary.delete(entry)
        if editorState?.bundleURL == entry.id { editorState = nil }
        if lastBundle?.url == entry.id { lastBundle = nil }
        refreshLibrary()
    }

    func renameRecording(_ entry: RecordingsLibrary.Entry, to newName: String) {
        guard let newURL = try? RecordingsLibrary.rename(entry, to: newName) else {
            refreshLibrary(); return
        }
        // If the renamed entry was open in the editor, swap to the new URL.
        if editorState?.bundleURL == entry.id {
            self.editorState = try? EditorState.load(bundleURL: newURL)
        }
        if lastBundle?.url == entry.id {
            lastBundle = ProjectBundle(url: newURL)
        }
        refreshLibrary()
    }

    // MARK: - record

    func startRecording() {
        guard #available(macOS 13.0, *) else {
            phase = .failed("Requires macOS 13+")
            return
        }
        // Single source of truth for "is a recording already in flight?".
        // Without this guard, rapid clicks (or ⌘R held) spawn parallel
        // RecordingSessions and AVCaptureSessions, deadlock on the camera,
        // and overwrite each other's bundles.
        guard canStartRecording else {
            BSLog.warn("startRecording ignored — phase=\(phase)")
            return
        }
        hiddenWindow = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        exportPhase = .none
        // Hide the main window NOW (before the 3-second countdown), not after
        // it. Otherwise the app's own UI gets captured for the first 3 seconds
        // of every recording — the exact thing julie hit in #2.
        hiddenWindow?.orderOut(nil)
        phase = .countingDown

        countdown.run(seconds: 3) { [weak self] in
            guard let self else { return }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard #available(macOS 13.0, *) else { return }
        // Release the camera from the home preview before WebcamRecorder opens it.
        // Two AVCaptureSessions on the same camera collide → AVError -11800 / hang.
        if includeWebcam {
            webcamPreview?.stop()
        }
        let session = RecordingSession(options: .init(
            includeWebcam: includeWebcam,
            includeSystemAudio: includeSystemAudio,
            includeMic: includeMic,
            captureTarget: selectedTarget
        ))
        self.session = session
        phase = .recording

        // Menu bar status item — primary, always-visible Stop with timer.
        menuBar.onStop = { [weak self] in self?.stopRecording() }
        menuBar.show()

        // Floating panel — opt-in only.
        if showFloatingPanel {
            recordingPanel.onStop = { [weak self] in self?.stopRecording() }
            let webcamSession = (includeWebcam && webcamPreview?.isRunning == true)
                ? webcamPreview?.session : nil
            recordingPanel.show(
                webcamSession: webcamSession,
                levels: session.levels
            )
        }

        Task { [weak self] in
            do {
                let dir = try Self.recordingsDirectory()
                _ = try await session.start(in: dir)
            } catch {
                await MainActor.run {
                    self?.recordingPanel.hide()
                    self?.menuBar.hide()
                    self?.restoreWindow()
                    self?.phase = .failed("Start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopRecording() {
        guard #available(macOS 13.0, *), let session = session as? RecordingSession else { return }
        // Symmetrical to the startRecording guard: ⌘⇧. + the menu-bar Stop +
        // the floating panel Stop can all fire while the user mashes them.
        // RecordingSession.stop() has `precondition(state == .recording)` —
        // a second call without this guard crashes the app.
        guard phase == .recording else {
            BSLog.warn("stopRecording ignored — phase=\(phase)")
            return
        }
        phase = .finalizing
        recordingPanel.hide()
        menuBar.hide()
        Task { [weak self] in
            do {
                let bundle = try await session.stop()
                await MainActor.run {
                    self?.lastBundle = bundle
                    self?.phase = .done(bundle)
                    self?.restoreWindow()
                    self?.loadEditor(for: bundle)
                    self?.refreshLibrary()
                    // If the user still has webcam toggled on, restart the home
                    // preview so they can see themselves on the next recording.
                    if let self = self, self.includeWebcam {
                        Task { await self.webcamPreview?.startIfPossible() }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.phase = .failed("Stop failed: \(error.localizedDescription)")
                    self?.restoreWindow()
                }
            }
        }
    }

    private func restoreWindow() {
        if let w = hiddenWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        hiddenWindow = nil
    }

    private func loadEditor(for bundle: ProjectBundle) {
        do {
            self.editorState = try EditorState.load(bundleURL: bundle.url)
        } catch {
            self.phase = .failed("Editor load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - export

    func polishAndExport() {
        guard #available(macOS 13.0, *), let editor = editorState else { return }
        let outputURL = editor.bundleURL.appendingPathComponent("polished.mp4")
        exportPhase = .running(progress: 0)

        let exporter = ExportPipeline()
        self.exporter = exporter
        exporter.onProgress = { [weak self] p in
            Task { @MainActor in self?.exportPhase = .running(progress: p) }
        }

        let project = editor.project
        let bundleURL = editor.bundleURL
        // Compute target dims from resolution preset, preserving canvas aspect.
        let targetSize: (Int, Int)? = {
            guard let h = exportResolution.heightPx else { return nil }
            let aspect = Double(project.canvas.widthPx) / Double(project.canvas.heightPx)
            let w = Int(Double(h) * aspect)
            // Even dimensions for H.264.
            return (w & ~1, h & ~1)
        }()

        let audioMode: ExportPipeline.AudioMode = {
            switch exportAudio {
            case .both: return .both
            case .micOnly: return .micOnly
            case .systemOnly: return .systemOnly
            case .mute: return .mute
            }
        }()

        Task { [weak self] in
            do {
                let url = try await exporter.run(.init(
                    project: project, bundleURL: bundleURL,
                    outputURL: outputURL, fps: 60,
                    bitrate: self?.exportResolution.defaultBitrate ?? 12_000_000,
                    targetSize: targetSize,
                    audioMode: audioMode
                ))
                await MainActor.run {
                    self?.exportPhase = .completed(url)
                }
            } catch {
                await MainActor.run {
                    self?.exportPhase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelExport() {
        if #available(macOS 13.0, *), let exporter = exporter as? ExportPipeline {
            exporter.cancel()
        }
    }

    private static func recordingsDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .moviesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("BaseStudio", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
