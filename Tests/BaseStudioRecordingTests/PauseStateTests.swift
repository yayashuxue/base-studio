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

    func testAudioBufferCrossingAPauseIsDropped() {
        let p = PauseState()
        let d = CMTime(seconds: 0.02, preferredTimescale: 48_000)
        p.pause(at: t(10))
        XCTAssertFalse(p.overlaps(t(9.97), duration: d))   // ends before the pause
        XCTAssertTrue(p.overlaps(t(9.99), duration: d))    // runs into the open pause
        XCTAssertTrue(p.overlaps(t(11), duration: d))
        p.resume(at: t(13))
        XCTAssertTrue(p.overlaps(t(9.99), duration: d))    // still crosses the closed pause start
        XCTAssertTrue(p.overlaps(t(12.99), duration: d))   // starts inside, ends after
        XCTAssertFalse(p.overlaps(t(13), duration: d))     // starts at resume
        XCTAssertFalse(p.overlaps(t(13.5), duration: .invalid))
        XCTAssertEqual(p.openPauseStart, nil)
        p.pause(at: t(20))
        XCTAssertEqual(p.openPauseStart?.seconds, 20)
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
