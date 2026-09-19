import AVFoundation
import AppKit
import BaseStudioCore
import BaseStudioRecording
import BaseStudioRender
import Foundation

/// In-app E2E harness (小o's local signed-app gate). Launched with
/// `--selftest-record`, the *signed* app drives the REAL recording stack
/// itself — record → stop → reopen → export, twice — inside a genuine
/// window-server + GPU session, then writes a machine-readable JSON report and
/// exits. This is the gate that catches `-12785`-class corruption that a
/// headless CI (no ScreenCaptureKit permission / no HW encoder session) can't.
///
/// Report path: `--selftest-out <path>` or /tmp/base-studio-selftest.json.
/// Exits 0 if every check passed, 1 otherwise.
@available(macOS 13.0, *)
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest-record")
    }

    private static var reportPath: String {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-out"),
           i + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[i + 1]
        }
        return "/tmp/base-studio-selftest.json"
    }

    static func runIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            var report = Report()
            do {
                try await run(into: &report)
            } catch {
                report.error = "\(error)"
                report.pass = false
            }
            write(report)
            NSApp.terminate(nil)
            // terminate() may be deferred; force-exit so the launcher gets the code.
            exit(report.pass ? 0 : 1)
        }
    }

    @MainActor
    private static func run(into report: inout Report) async throws {
        let dir = try recordingsDir()
        var lastBundle: ProjectBundle?

        // Let the window server / GPU settle after launch, and hide our own
        // live-rendering window so screen capture doesn't fight the SwiftUI
        // Metal surface for the encoder — recording our own actively-drawing
        // window the instant we launch reliably malfunctions the H.264 session
        // (-16122 / -12785 on frame 1). The manual flow hides the window + runs
        // a 3s countdown for the same reason.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        for w in NSApp.windows where !(w is NSPanel) { w.orderOut(nil) }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Two rounds: stop → record again → stop must still yield 3 good tracks
        // (webcam must not vanish on the second run).
        // Diagnostic: --selftest-no-webcam isolates the screen encoder from the
        // concurrent webcam H.264 session (to tell a concurrent-encoder startup
        // race apart from a resolution / machine-state issue).
        let withWebcam = !CommandLine.arguments.contains("--selftest-no-webcam")
        for i in 1...2 {
            var r = RunResult(index: i)
            let session = RecordingSession(options: .init(
                includeWebcam: withWebcam, includeSystemAudio: true, includeMic: withWebcam
            ))
            let bundle = try await session.start(in: dir, name: "selftest-\(i)")
            try await Task.sleep(nanoseconds: 4_000_000_000)
            _ = try await session.stop()
            lastBundle = bundle

            let fm = FileManager.default
            r.failureJson = fm.fileExists(atPath: bundle.failureURL.path)
            r.metadata = fm.fileExists(atPath: bundle.metadataURL.path)

            // screen.mov must be a real decodable movie (moov present).
            let asset = AVURLAsset(url: bundle.screenURL)
            let vids = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            r.screenTrack = !vids.isEmpty
            r.screenDurationSec = (try? await asset.load(.duration).seconds) ?? 0
            if let t = vids.first {
                let sz = (try? await t.load(.naturalSize)) ?? .zero
                r.screenDims = "\(Int(sz.width))x\(Int(sz.height))"
            }
            // Webcam + mic tracks non-empty.
            r.webcamTrack = trackNonEmpty(bundle.url.appendingPathComponent("webcam.mov"), .video)
            r.micTrack = trackNonEmpty(bundle.url.appendingPathComponent("mic.m4a"), .audio)

            // Reopen through the real editor loader.
            do {
                _ = try EditorState.load(bundleURL: bundle.url)
                r.openOk = true
            } catch {
                r.openOk = false
                r.openError = "\(error)"
            }
            r.pass = !r.failureJson && r.metadata && r.screenTrack
                && r.screenDurationSec > 1.0 && r.openOk
                && (!withWebcam || (r.webcamTrack && r.micTrack))
            report.runs.append(r)
        }

        // Export the last good bundle through the real pipeline.
        if let bundle = lastBundle {
            do {
                let editor = try EditorState.load(bundleURL: bundle.url)
                let out = bundle.url.appendingPathComponent("selftest-export.mp4")
                let pipeline = ExportPipeline()
                let url = try await pipeline.run(.init(
                    project: editor.project, bundleURL: bundle.url,
                    outputURL: out, fps: 60, bitrate: 8_000_000, audioMode: .both
                ))
                let asset = AVURLAsset(url: url)
                let vids = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                report.exportOk = !vids.isEmpty
                    && FileManager.default.fileExists(atPath: url.path)
                report.exportDurationSec = (try? await asset.load(.duration).seconds) ?? 0
            } catch {
                report.exportOk = false
                report.exportError = "\(error)"
            }
        }

        report.pass = report.runs.allSatisfy { $0.pass } && report.exportOk
    }

    private static func trackNonEmpty(_ url: URL, _ type: AVMediaType) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            let tracks = (try? await asset.loadTracks(withMediaType: type)) ?? []
            ok = !tracks.isEmpty
            sem.signal()
        }
        sem.wait()
        return ok
    }

    private static func recordingsDir() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BaseStudio/SelfTest", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func write(_ report: Report) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(report) {
            try? data.write(to: URL(fileURLWithPath: reportPath))
        }
    }

    struct Report: Codable {
        var runs: [RunResult] = []
        var exportOk = false
        var exportDurationSec: Double = 0
        var exportError: String?
        var error: String?
        var pass = false
    }

    struct RunResult: Codable {
        var index: Int
        var pass = false
        var failureJson = false
        var metadata = false
        var screenTrack = false
        var screenDims = ""
        var screenDurationSec: Double = 0
        var webcamTrack = false
        var micTrack = false
        var openOk = false
        var openError: String?
    }
}
