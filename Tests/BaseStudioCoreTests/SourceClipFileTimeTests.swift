import CoreMedia
import XCTest
@testable import BaseStudioCore

/// Regression tests for the camera-replay bug. Pre-fix, `EditorState`/
/// `ExportPipeline` passed host-clock PTSes to `AVAssetImageGenerator` for
/// non-primary sources, but the on-disk webcam.mov has its track shifted to
/// file-time 0 by `AVAssetWriter.startSession(atSourceTime:)`. With the tight
/// post-fix tolerance the seek would now fail outright; with the legacy
/// `.positiveInfinity` tolerance it silently clamped to the last frame.
///
/// `SourceClip.fileTime(at:)` is the single conversion that prevents both
/// failure modes — these tests pin its behavior so the bug can't quietly
/// reappear.
final class SourceClipFileTimeTests: XCTestCase {

    private func clip(firstPTSSec: Double, id: String = "webcam") -> SourceClip {
        SourceClip(
            id: id, relativeMediaPath: "\(id).mov",
            widthPx: 1280, heightPx: 720,
            firstPTS: TimePoint(CMTime(seconds: firstPTSSec, preferredTimescale: 600)),
            sidecars: []
        )
    }

    func testHostPTSAtFirstFrameMapsToZero() {
        let webcam = clip(firstPTSSec: 1_133_778.5)
        let hostPTS = webcam.firstPTS.cmTime
        XCTAssertEqual(webcam.fileTime(at: hostPTS).seconds, 0, accuracy: 1e-6)
    }

    func testHostPTSAfterFirstFrameMapsToOffset() {
        // Webcam recorder started at host-clock 1_133_778.5s. Five seconds
        // into the recording, the host-PTS is firstPTS + 5s.
        let webcam = clip(firstPTSSec: 1_133_778.5)
        let hostPTS = CMTimeAdd(
            webcam.firstPTS.cmTime,
            CMTime(seconds: 5.0, preferredTimescale: 600)
        )
        XCTAssertEqual(webcam.fileTime(at: hostPTS).seconds, 5.0, accuracy: 1e-6)
    }

    func testHostPTSBeforeFirstFrameClampsToZero() {
        // When the webcam recorder starts a few hundred ms after the screen
        // recorder (camera warm-up), early timeline PTSes correspond to
        // host-PTSes earlier than the webcam's first frame. There is no
        // matching webcam frame for those instants — clamping to file-time 0
        // (the first frame) is the correct fallback.
        let webcam = clip(firstPTSSec: 1_133_778.5)
        let earlier = CMTimeSubtract(
            webcam.firstPTS.cmTime,
            CMTime(seconds: 0.3, preferredTimescale: 600)
        )
        XCTAssertEqual(webcam.fileTime(at: earlier).seconds, 0, accuracy: 1e-6)
    }

    func testCrossSourceAlignment() {
        // Screen and webcam start ~250ms apart but share the host clock.
        // At timeline t (relative to the screen's first frame), the webcam
        // file-time should be (t - delta) when t > delta, else 0.
        let screenStart = 1_133_778.5
        let webcamStart = screenStart + 0.25
        let screen = clip(firstPTSSec: screenStart, id: "screen")
        let webcam = clip(firstPTSSec: webcamStart)

        for tlSec in [0.0, 0.1, 0.25, 0.5, 1.0, 4.0] {
            let hostAtTimeline = CMTimeAdd(
                screen.firstPTS.cmTime,
                CMTime(seconds: tlSec, preferredTimescale: 600)
            )
            let expected = max(0, tlSec - 0.25)
            XCTAssertEqual(
                webcam.fileTime(at: hostAtTimeline).seconds,
                expected, accuracy: 1e-6,
                "timeline t=\(tlSec) → webcam file-time"
            )
        }
    }

    func testRecordingMetadataSourcesRoundTrip() throws {
        let info = SourceMediaInfo(
            firstVideoPTS: TimePoint(CMTime(seconds: 100, preferredTimescale: 600)),
            lastVideoPTS: TimePoint(CMTime(seconds: 110, preferredTimescale: 600)),
            widthPx: 1280, heightPx: 720
        )
        let meta = RecordingMetadata(
            displayID: 1, widthPx: 3024, heightPx: 1964, pointScale: 2,
            displayOriginXPt: 0, displayOriginYPt: 0,
            displayWidthPt: 1512, displayHeightPt: 982,
            firstVideoPTS: TimePoint(CMTime(seconds: 99, preferredTimescale: 600)),
            lastVideoPTS: TimePoint(CMTime(seconds: 109, preferredTimescale: 600)),
            sources: ["screen": info, "webcam": info]
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: data)
        XCTAssertEqual(decoded.sources?["webcam"]?.firstVideoPTS, info.firstVideoPTS)
        XCTAssertEqual(decoded.sources?.count, 2)
    }

    func testRecordingMetadataLegacyDecodeWithoutSources() throws {
        // Old recordings written before per-source info was added must keep
        // decoding cleanly — `sources` is optional.
        let legacyJSON = """
        {
          "displayID": 1,
          "widthPx": 3024,
          "heightPx": 1964,
          "pointScale": 2,
          "displayOriginXPt": 0,
          "displayOriginYPt": 0,
          "displayWidthPt": 1512,
          "displayHeightPt": 982,
          "firstVideoPTS": {"value": 100, "timescale": 600},
          "lastVideoPTS": {"value": 200, "timescale": 600}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: legacyJSON)
        XCTAssertNil(decoded.sources)
        XCTAssertEqual(decoded.firstVideoPTS.cmTime.seconds, 100.0/600.0, accuracy: 1e-9)
    }
}
