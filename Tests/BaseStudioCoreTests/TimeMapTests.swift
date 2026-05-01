import CoreMedia
import XCTest
@testable import BaseStudioCore

/// PRD §3 invariant: speed is one piecewise function `f(timeline) → source_time`,
/// shared by video sampling and audio resampling. These tests pin the function so
/// the two subsystems cannot drift, and so future "render the speed-up to a temp
/// file" shortcuts (PRD §11 anti-pattern) get caught at the unit level.
final class TimeMapTests: XCTestCase {

    // MARK: identity / clamping

    func testIdentityMapsTimelineToSourceOneToOne() {
        let m = TimeMap.identity(trimInSec: 0, trimOutSec: 10)
        for t in stride(from: 0.0, through: 10.0, by: 0.5) {
            XCTAssertEqual(m.sourceSec(at: t), t, accuracy: 1e-9)
        }
    }

    func testIdentityClampsOutOfRange() {
        let m = TimeMap.identity(trimInSec: 0, trimOutSec: 5)
        XCTAssertEqual(m.sourceSec(at: -3.0), 0, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 99.0), 5.0, accuracy: 1e-9)
    }

    func testTrimInShiftsHostPTSReturnButNotSourceSec() {
        // sourceSec is in source-relative time (0 = trim in). trimInSec only
        // surfaces in sourcePTS (host clock), so identity with trimIn=2 still
        // returns sourceSec(0)=0.
        let m = TimeMap.identity(trimInSec: 2, trimOutSec: 5)
        XCTAssertEqual(m.sourceSec(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 3), 3, accuracy: 1e-9)  // duration capped
    }

    // MARK: speed regions

    func testSingleDoubleSpeedRegion() {
        // 10s of source. Region [2,8] @ 2x ⇒ 6s of source plays in 3s of timeline.
        // Expected segments: [0..2 @ 1x] [2..8 @ 2x] [8..10 @ 1x].
        // Timeline: [0..2 @ 1x] = 2s, [2..5 @ 2x] = 3s, [5..7 @ 1x] = 2s. Total 7s.
        let m = TimeMap.make(
            trimInSec: 0, trimOutSec: 10,
            speedRegions: [(2, 8, 2.0)]
        )
        XCTAssertEqual(m.timelineDurationSec, 7, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 2), 2, accuracy: 1e-9)        // entering 2x region
        XCTAssertEqual(m.sourceSec(at: 3.5), 5, accuracy: 1e-9)      // 1.5s timeline @2x = 3s source past 2
        XCTAssertEqual(m.sourceSec(at: 5), 8, accuracy: 1e-9)        // exit 2x
        XCTAssertEqual(m.sourceSec(at: 7), 10, accuracy: 1e-9)
    }

    func testSlowMoRegionStretchesTimeline() {
        // 10s of source. Region [4,6] @ 0.5x ⇒ 2s source plays over 4s timeline.
        // Total timeline: 4 + 4 + 4 = 12s.
        let m = TimeMap.make(
            trimInSec: 0, trimOutSec: 10,
            speedRegions: [(4, 6, 0.5)]
        )
        XCTAssertEqual(m.timelineDurationSec, 12, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 4), 4, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 6), 5, accuracy: 1e-9)        // 2s @0.5x = 1s source
        XCTAssertEqual(m.sourceSec(at: 8), 6, accuracy: 1e-9)
        XCTAssertEqual(m.sourceSec(at: 12), 10, accuracy: 1e-9)
    }

    func testMonotonicallyNonDecreasingUnderMixedSpeeds() {
        // The PRD's hardest invariant: f(t) is monotone. Without this, a/v
        // resamplers can read the same source range twice and audio "stutters".
        let m = TimeMap.make(
            trimInSec: 0, trimOutSec: 30,
            speedRegions: [(5, 10, 3.0), (15, 25, 0.5)]
        )
        var prev = -Double.infinity
        for t in stride(from: 0.0, through: m.timelineDurationSec, by: 0.05) {
            let s = m.sourceSec(at: t)
            XCTAssertGreaterThanOrEqual(s, prev - 1e-9, "non-monotone at t=\(t)")
            prev = s
        }
    }

    func testEndpointsExactToSamplePrecision() {
        // PRD test #7: SpeedCurve endpoints must land on the trim window
        // exactly, not "approximately". A 1-sample drift here multiplied by
        // 30 minutes of timeline turns into the audio-mix offset bug class.
        let m = TimeMap.make(
            trimInSec: 0, trimOutSec: 100,
            speedRegions: [(20, 80, 4.0)]
        )
        XCTAssertEqual(m.sourceSec(at: 0), 0, accuracy: 0)
        XCTAssertEqual(m.sourceSec(at: m.timelineDurationSec), 100, accuracy: 1e-9)
    }

    // MARK: sourcePTS — host-clock anchored

    func testSourcePTSAddsTrimAndFirstPTS() {
        let m = TimeMap.identity(trimInSec: 1.5, trimOutSec: 4.5)
        let firstPTS = CMTime(seconds: 1_000_000.0, preferredTimescale: 600)
        // Timeline t=0 ⇒ source-relative 0 ⇒ host = first + trimIn = 1_000_001.5
        XCTAssertEqual(
            m.sourcePTS(at: 0, firstPTS: firstPTS).seconds,
            1_000_001.5, accuracy: 1e-6
        )
        // Timeline t=2 ⇒ source-relative 2 ⇒ host = 1_000_003.5
        XCTAssertEqual(
            m.sourcePTS(at: 2, firstPTS: firstPTS).seconds,
            1_000_003.5, accuracy: 1e-6
        )
    }

    // MARK: TimeMap × SourceClip.fileTime composition

    func testFileTimeOfPrimaryUnderTrimAndSpeed() {
        // Primary clip: firstPTS = 1_000_000s (host-clock).
        // Trim: keep [3, 13]s of source (10s window). 2x speed-up across [3, 7].
        // At timeline t=2s: we're 2s into the 2x region, so source-relative=7s,
        // file-time on disk = trimIn(3) + 7 = 10s.
        let primary = SourceClip(
            id: "screen", relativeMediaPath: "screen.mov",
            widthPx: 3024, heightPx: 1964,
            firstPTS: TimePoint(CMTime(seconds: 1_000_000, preferredTimescale: 600)),
            sidecars: []
        )
        let m = TimeMap.make(
            trimInSec: 3, trimOutSec: 13,
            speedRegions: [(0, 4, 2.0)]   // first 4s of trimmed source @ 2x
        )
        let hostPTS = m.sourcePTS(at: 2.0, firstPTS: primary.firstPTS.cmTime)
        let fileTime = primary.fileTime(at: hostPTS).seconds
        XCTAssertEqual(fileTime, 7.0, accuracy: 1e-6)
    }

    func testFileTimeOfSecondaryAlignsToTimelineNotSourceTime() {
        // Webcam started 250ms after screen. Speed-curves on the primary do
        // NOT speed up the secondary — secondary always reads at timeline rate
        // (no per-source SpeedCurve in M0). At timeline t=1.0, the wallclock
        // delta from screen's start is 1.0s, so webcam file-time = max(0, 1.0 - 0.25) = 0.75.
        let screen = SourceClip(
            id: "screen", relativeMediaPath: "screen.mov",
            widthPx: 3024, heightPx: 1964,
            firstPTS: TimePoint(CMTime(seconds: 1_000_000, preferredTimescale: 600)),
            sidecars: []
        )
        let webcam = SourceClip(
            id: "webcam", relativeMediaPath: "webcam.mov",
            widthPx: 1280, heightPx: 720,
            firstPTS: TimePoint(CMTime(seconds: 1_000_000.25, preferredTimescale: 600)),
            sidecars: []
        )
        let timelineSec = 1.0
        let hostAtTimeline = CMTimeAdd(
            screen.firstPTS.cmTime,
            CMTime(seconds: timelineSec, preferredTimescale: 600)
        )
        XCTAssertEqual(webcam.fileTime(at: hostAtTimeline).seconds, 0.75, accuracy: 1e-6)
    }

    // MARK: real disk round-trip for RecordingMetadata

    func testRecordingMetadataDiskRoundTrip() throws {
        // Encoder→decoder is covered by SourceClipFileTimeTests; this one
        // writes to and reads back from a real temp file the way
        // RecordingSession.stop() does, to catch atomic-write or filesystem
        // issues that pure in-memory tests miss.
        let info = SourceMediaInfo(
            firstVideoPTS: TimePoint(CMTime(seconds: 1_234_567.5, preferredTimescale: 600)),
            lastVideoPTS: TimePoint(CMTime(seconds: 1_234_572.5, preferredTimescale: 600)),
            widthPx: 1280, heightPx: 720
        )
        let original = RecordingMetadata(
            displayID: 1, widthPx: 3024, heightPx: 1964, pointScale: 2,
            displayOriginXPt: 0, displayOriginYPt: 0,
            displayWidthPt: 1512, displayHeightPt: 982,
            firstVideoPTS: TimePoint(CMTime(seconds: 1_234_567.4, preferredTimescale: 600)),
            lastVideoPTS: TimePoint(CMTime(seconds: 1_234_577.4, preferredTimescale: 600)),
            sources: ["screen": info, "webcam": info]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(original).write(to: url, options: .atomic)
        let decoded = try JSONDecoder().decode(
            RecordingMetadata.self,
            from: try Data(contentsOf: url)
        )
        let webcamPTS = try XCTUnwrap(decoded.sources?["webcam"]?.firstVideoPTS.cmTime.seconds)
        XCTAssertEqual(webcamPTS, info.firstVideoPTS.cmTime.seconds, accuracy: 1e-6)
        XCTAssertEqual(decoded.sources?.count, 2)
        XCTAssertEqual(
            decoded.firstVideoPTS.cmTime.seconds,
            original.firstVideoPTS.cmTime.seconds,
            accuracy: 1e-6
        )
    }
}
