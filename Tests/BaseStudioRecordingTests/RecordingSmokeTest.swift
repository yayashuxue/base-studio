import AVFoundation
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRecording

/// REAL end-to-end recording smoke test through the actual capture stack
/// (ScreenCaptureKit → AVAssetWriter), used to verify the 1920 screen-capture
/// cap produces a VALID bundle instead of the -12785 corruption. Records the
/// live screen for ~4s, so it's gated behind BS_RECORD_SMOKE=1 (needs Screen
/// Recording permission for the running process) and skips loudly otherwise —
/// it must never silently pass.
@available(macOS 13.0, *)
final class RecordingSmokeTest: XCTestCase {

    func testScreenRecordingProducesValidBundle() async throws {
        guard ProcessInfo.processInfo.environment["BS_RECORD_SMOKE"] == "1" else {
            throw XCTSkip("Set BS_RECORD_SMOKE=1 to run the live screen-recording smoke test.")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Screen + system audio, no webcam/mic (camera/mic TCC may not be
        // granted to the test host). This exercises the SCK→H.264 path that
        // regressed to -12785 at full 3024×1964.
        let session = RecordingSession(options: .init(
            includeWebcam: false, includeSystemAudio: true, includeMic: false
        ))
        let bundle = try await session.start(in: dir, name: "smoke")
        try await Task.sleep(nanoseconds: 4 * 1_000_000_000)
        _ = try await session.stop()

        // No failure sidecar, metadata written = finalize succeeded (not -12785).
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.failureURL.path),
                       "recording left a failure.json — finalize failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.metadataURL.path),
                      "no metadata.json — stop() threw before writing it")

        // screen.mov must be a real, readable H.264 movie (moov present).
        let asset = AVURLAsset(url: bundle.screenURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "screen.mov has no readable video track (corrupt/moov missing)")
        let dur = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(dur, 1.0, "screen.mov too short — capture didn't run")

        // Confirm the reliability cap took effect (long edge <= 1920).
        if let t = tracks.first {
            let size = try await t.load(.naturalSize)
            XCTAssertLessThanOrEqual(Int(max(size.width, size.height)), 1920,
                                     "screen capture exceeded the reliability cap")
            print("SMOKE: screen.mov \(Int(size.width))x\(Int(size.height)), \(String(format: "%.1f", dur))s, no failure.json ✓")
        }
    }
}
