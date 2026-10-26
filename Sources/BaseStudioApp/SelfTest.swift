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

    /// `--selftest-seconds N` (default 4). Long takes + the test-only
    /// BS_INJECT_SCREEN_FAIL_AT_FRAMES env exercise mid-recording encoder recovery.
    private static var recordSeconds: Double {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-seconds"),
           i + 1 < CommandLine.arguments.count, let v = Double(CommandLine.arguments[i + 1]) {
            return max(1, v)
        }
        return 4
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
        if CommandLine.arguments.contains("--selftest-synthetic-writer") {
            report.syntheticWriter = await syntheticWriterProbe()
            report.pass = report.syntheticWriter?.hasPrefix("ok") == true
            return
        }
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
            // Fresh bundle every run — leftovers from earlier runs (edl.json,
            // failure.json, exports) made good takes look broken.
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("selftest-\(i).basestudio"))
            let bundle = try await session.start(in: dir, name: "selftest-\(i)")
            try await Task.sleep(nanoseconds: UInt64(recordSeconds * 1_000_000_000))
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
            // Webcam + mic tracks present AND with real duration (not just an
            // empty header). Fully async — NO DispatchSemaphore on the main
            // actor (that deadlocks the instant a real recording succeeds and
            // reaches this check, so the report would never come out).
            r.webcamTrack = await trackPlayable(bundle.url.appendingPathComponent("webcam.mov"), .video)
            r.micTrack = await trackPlayable(bundle.url.appendingPathComponent("mic.m4a"), .audio)

            // Reopen through the real editor loader.
            do {
                _ = try EditorState.load(bundleURL: bundle.url)
                r.openOk = true
            } catch {
                r.openOk = false
                r.openError = "\(error)"
            }
            // The screen must cover (almost) the whole take — a recovered
            // encoder failure may cost < 1 s, never the rest of the take.
            r.recordSeconds = recordSeconds
            r.pass = !r.failureJson && r.metadata && r.screenTrack
                && r.screenDurationSec > max(1.0, recordSeconds - 1.5) && r.openOk
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
                report.exportDurationSec = (try? await asset.load(.duration).seconds) ?? 0
                report.exportOk = !vids.isEmpty
                    && FileManager.default.fileExists(atPath: url.path)
                    && report.exportDurationSec > 0.5
            } catch {
                report.exportOk = false
                report.exportError = "\(error)"
            }
        }

        report.pass = report.runs.allSatisfy { $0.pass } && report.exportOk
    }

    private static func trackPlayable(_ url: URL, _ type: AVMediaType) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: type)) ?? []
        guard !tracks.isEmpty else { return false }
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        return dur > 1.0
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

    /// Isolates "is the encoder/writer broken in this process?" from "are the
    /// SCK buffers bad?": 3 s of 1512x982 NV12 frames drawn on the CPU, same
    /// settings as the screen recorder, then finishWriting.
    static func syntheticWriterProbe() async -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-synth-\(UUID().uuidString).mov")
        let w = 1512, h = 982, fps = 60
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return "fail: writer init" }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, w * h * fps / 12),
                                              AVVideoMaxKeyFrameIntervalKey: fps * 2,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
        guard writer.startWriting() else { return "fail: startWriting \(String(describing: writer.error))" }
        writer.startSession(atSourceTime: .zero)
        var appended = 0
        for i in 0..<(fps * 3) {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { return "fail: no pool, status=\(writer.status.rawValue) \(String(describing: writer.error))" }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return "fail: no buffer" }
            CVPixelBufferLockBaseAddress(pb, [])
            if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                memset(y, Int32(16 + (i * 3) % 200), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * h)
            }
            if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
                return "fail: append at frame \(i), status=\(writer.status.rawValue) \(String(describing: writer.error))"
            }
            appended += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        defer { try? FileManager.default.removeItem(at: url) }
        return writer.status == .completed ? "ok: \(appended) frames finalized" : "fail: finish status=\(writer.status.rawValue) \(String(describing: writer.error))"
    }

    struct Report: Codable {
        var runs: [RunResult] = []
        var exportOk = false
        var exportDurationSec: Double = 0
        var exportError: String?
        var error: String?
        var pass = false
        /// `--selftest-synthetic-writer`: same H.264 writer settings fed with
        /// CPU-made NV12 frames instead of ScreenCaptureKit buffers.
        var syntheticWriter: String?
    }

    struct RunResult: Codable {
        var index: Int
        var pass = false
        var failureJson = false
        var metadata = false
        var screenTrack = false
        var screenDims = ""
        var screenDurationSec: Double = 0
        var recordSeconds: Double = 0
        var webcamTrack = false
        var micTrack = false
        var openOk = false
        var openError: String?
    }
}
