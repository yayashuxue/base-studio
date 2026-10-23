import AVFoundation
import CoreMedia
import XCTest
@testable import BaseStudioRecording

/// Mid-recording encoder recovery: the screen recorder writes fragmented
/// segments and, after a -12785-style failure, continues in a new segment.
/// These tests check the part that runs without VideoToolbox — that a segment
/// whose writer died mid-file is still readable, and that `stitch` puts the
/// segments back on the original timeline (gaps preserved, so the screen
/// stays in sync with webcam/mic). Segments are made by ffmpeg (software
/// x264), so this runs headless.
final class ScreenSegmentStitchTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        guard let _ = Self.ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs-stitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    static let ffmpeg: String? = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A fragmented H.264 .mov like the recorder writes (fragment every 2 s).
    private func makeSegment(_ name: String, seconds: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg!)
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30",
                       "-t", "\(seconds)", "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p",
                       "-movflags", "frag_keyframe+empty_moov", "-frag_duration", "2000000", url.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "ffmpeg failed")
        return url
    }

    private func duration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let v = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(v.isEmpty, "no video track in \(url.lastPathComponent)")
        return try await asset.load(.duration).seconds
    }

    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    func testSegmentAbandonedMidWriteIsStillReadable() async throws {
        // An encoder that dies mid-take never finalizes: the file just stops.
        // Simulate by truncating a 10 s fragmented file to ~60 %.
        let url = try makeSegment("screen.mov", seconds: 10)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(Double(size) * 0.6))
        try h.close()
        let d = try await duration(url)
        XCTAssertGreaterThan(d, 2.0, "fragments before the failure must survive (got \(d)s)")
        XCTAssertLessThan(d, 10.0)
    }

    func testStitchKeepsOriginalTimelineAcrossARecovery() async throws {
        // Take starts at host time 100 s. Segment 1 covers 100–106 s, the
        // encoder dies, segment 2 resumes at 107 s and runs 4 s (→ 111 s).
        let s1 = try makeSegment("screen.mov", seconds: 6)
        let s2 = try makeSegment("screen.part1.mov", seconds: 4)
        let out = dir.appendingPathComponent("screen.mov")
        try await ScreenRecorder.stitch(
            segments: [(s1, t(100)), (s2, t(107))], origin: t(100), into: out
        )
        let d = try await duration(out)
        XCTAssertEqual(d, 11.0, accuracy: 0.2, "gap must be preserved so screen stays in sync")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s2.path), "part files are cleaned up")
    }

    func testStitchSkipsUnreadableSegmentsButKeepsTheRest() async throws {
        let good = try makeSegment("screen.mov", seconds: 5)
        let junk = dir.appendingPathComponent("screen.part1.mov")
        try Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70]).write(to: junk) // header only, no video
        let out = dir.appendingPathComponent("screen.mov")
        try await ScreenRecorder.stitch(segments: [(good, t(0)), (junk, t(6))], origin: t(0), into: out)
        let d = try await duration(out)
        XCTAssertEqual(d, 5.0, accuracy: 0.2)
    }

    func testStitchFailsLoudlyWhenNothingIsReadable() async throws {
        let junk = dir.appendingPathComponent("screen.mov")
        try Data([0, 0, 0, 8]).write(to: junk)
        do {
            try await ScreenRecorder.stitch(segments: [(junk, t(0))], origin: t(0), into: junk)
            XCTFail("stitching nothing must throw, not produce an empty file")
        } catch {}
    }

    func testSegmentsWithoutAStartTimeAreIgnored() async throws {
        // A replacement segment opened right before stop() never received a
        // frame (start stays .invalid) — it must not shift or break the result.
        let s1 = try makeSegment("screen.mov", seconds: 4)
        let unused = dir.appendingPathComponent("screen.part1.mov")
        let out = dir.appendingPathComponent("screen.mov")
        try await ScreenRecorder.stitch(segments: [(s1, t(50)), (unused, .invalid)], origin: t(50), into: out)
        let d = try await duration(out)
        XCTAssertEqual(d, 4.0, accuracy: 0.2)
    }
}
