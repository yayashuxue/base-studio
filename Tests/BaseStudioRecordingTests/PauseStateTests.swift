import CoreMedia
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRecording

/// Pause = nothing written: every recorder asks PauseState per sample.
final class PauseStateTests: XCTestCase {
    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_000_000) }

    func testCoversOpenAndClosedPauses() {
        let p = PauseState()
        XCTAssertFalse(p.covers(t(5)))
        p.pause(at: t(10))
        XCTAssertTrue(p.isPaused)
        XCTAssertFalse(p.covers(t(9.999)))
        XCTAssertTrue(p.covers(t(10)))      // from the pause instant on
        XCTAssertTrue(p.covers(t(50)))      // still open
        p.resume(at: t(13))
        XCTAssertFalse(p.isPaused)
        XCTAssertTrue(p.covers(t(12.9)))
        XCTAssertFalse(p.covers(t(13)))     // resume instant is recorded
        p.pause(at: t(20)); p.pause(at: t(21))   // double pause keeps the first
        let all = p.finish(at: t(25))            // Stop while paused closes it
        XCTAssertEqual(all.map { $0.start.seconds }, [10, 20])
        XCTAssertEqual(all.map { $0.end.seconds }, [13, 25])
    }

    func testPausesBecomeCutsFromFirstFrame() {
        let meta = RecordingMetadata(
            displayID: 1, widthPx: 100, heightPx: 100, pointScale: 1,
            displayOriginXPt: 0, displayOriginYPt: 0, displayWidthPt: 100, displayHeightPt: 100,
            firstVideoPTS: TimePoint(t(100)), lastVideoPTS: TimePoint(t(130)),
            pauses: [PauseInterval(start: TimePoint(t(110)), end: TimePoint(t(113)))])
        XCTAssertEqual(meta.pauseCuts, [SourceCut(startSec: 10, endSec: 13)])
        // Round-trips through metadata.json; old files without it still load.
        let data = try! JSONEncoder().encode(meta)
        XCTAssertEqual(try! JSONDecoder().decode(RecordingMetadata.self, from: data).pauses?.count, 1)
    }
}
