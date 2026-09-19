import AVFoundation
import CoreMedia
import XCTest

/// CI-runnable recorder validation (小o's CI gate). Does NOT use
/// ScreenCaptureKit or a camera (those need permissions + a window-server
/// session a headless runner lacks). Instead it drives the SAME AVAssetWriter
/// H.264 path the recorders use — two concurrent video writers (screen-sized +
/// webcam-sized) plus an audio writer — with synthetic frames, across the
/// supported dimension set, and asserts every writer finalizes `.completed`
/// with a decodable `moov` + non-empty track. This catches encoder-settings /
/// dimension regressions deterministically; the live SCK path is covered by the
/// signed-app --selftest-record gate.
final class SyntheticRecorderTest: XCTestCase {

    func testConcurrentEncodersFinalizeAcrossDimensions() async throws {
        // VideoToolbox H.264 encoding needs a window-server session; a plain
        // headless xctest host doesn't have one and -12785s regardless of the
        // code. Gate behind BS_SYNTH_RECORD=1 so this runs where a session
        // exists (a GUI-login CI runner, or `swift test` from a logged-in
        // Terminal) and skips loudly — never a silent pass — otherwise. The
        // live SCK path is separately covered by the signed-app self-test gate.
        guard ProcessInfo.processInfo.environment["BS_SYNTH_RECORD"] == "1" else {
            throw XCTSkip("Set BS_SYNTH_RECORD=1 (needs a window-server session) to run the concurrent-encoder test.")
        }
        // (screen w, screen h) combos a real display + the reliability cap yield.
        for dims in [(1512, 982), (1920, 1080), (2560, 1440)] {
            try await runConcurrent(screenW: dims.0, screenH: dims.1)
        }
    }

    private func runConcurrent(screenW: Int, screenH: Int) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs-synth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let screen = try Video(dir.appendingPathComponent("screen.mov"), w: screenW, h: screenH,
                               bitrate: max(8_000_000, screenW * screenH * 60 / 12))
        let webcam = try Video(dir.appendingPathComponent("webcam.mov"), w: 1280, h: 720, bitrate: 6_000_000)

        let fps: Int32 = 60
        let frames = 120   // 2s
        for i in 0..<frames {
            let pts = CMTime(value: CMTimeValue(i), timescale: fps)
            screen.append(pts)
            webcam.append(pts)
            XCTAssertNotEqual(screen.writer.status, .failed,
                              "screen writer failed at frame \(i) (\(screenW)x\(screenH)): \(String(describing: screen.writer.error))")
            XCTAssertNotEqual(webcam.writer.status, .failed, "webcam writer failed at frame \(i)")
        }
        try await screen.finish()
        try await webcam.finish()

        for (label, v) in [("screen \(screenW)x\(screenH)", screen), ("webcam", webcam)] {
            XCTAssertEqual(v.writer.status, .completed, "\(label) did not finalize .completed")
            let asset = AVURLAsset(url: v.url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1, "\(label): output has no readable video track (moov missing / corrupt)")
            let dur = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(dur, 1.0, "\(label): output too short")
        }
    }

    /// Minimal H.264 video writer with a pixel-buffer adaptor, mirroring the
    /// recorders' AVAssetWriter settings.
    private final class Video {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor

        init(_ url: URL, w: Int, h: Int, bitrate: Int) throws {
            self.url = url
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoMaxKeyFrameIntervalKey: 120,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        }

        func append(_ pts: CMTime) {
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            if let pb { _ = adaptor.append(pb, withPresentationTime: pts) }
        }

        func finish() async throws {
            input.markAsFinished()
            await writer.finishWriting()
        }
    }
}
