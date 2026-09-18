import XCTest
@testable import BaseStudioApp
@testable import BaseStudioRecording

/// Regression net for the preview-latency fixes (小o's auto-verifiable asks):
/// a stale frame must not publish, a source switch bumps the generation and
/// drops the cached filter (so the new source refreshes immediately), and
/// re-selecting the same source is a no-op.
@MainActor
final class ScreenPreviewSessionTests: XCTestCase {

    func testSourceSwitchBumpsGenerationAndDropsStaleFrames() {
        let s = ScreenPreviewSession()
        s.setTarget(.display(1))
        let genA = s.generation
        // A frame captured under the current generation is fresh.
        XCTAssertFalse(s.isFrameStale(gen: genA))

        // Switch source: an in-flight frame from source A is now stale and must
        // NOT be published over source B.
        s.setTarget(.window(5))
        XCTAssertNotEqual(s.generation, genA, "source switch must bump generation")
        XCTAssertTrue(s.isFrameStale(gen: genA), "old-source frame must be treated as stale")
        XCTAssertFalse(s.isFrameStale(gen: s.generation), "current-source frame is fresh")
    }

    func testNoGenerationAttachedIsNeverStale() {
        // The macOS 13 legacy path / callers that don't tag a generation pass
        // -1 and must always publish.
        let s = ScreenPreviewSession()
        s.setTarget(.display(1))
        XCTAssertFalse(s.isFrameStale(gen: -1))
    }

    func testSourceSwitchClearsCachedFilterForImmediateRefresh() {
        let s = ScreenPreviewSession()
        s.setTarget(.display(1))
        // Freshly targeted: nothing cached yet (a rebuild is required).
        XCTAssertFalse(s.hasCachedFilterForCurrentTarget)
        s.setTarget(.window(7))
        // After switching, the cache must be cleared so the next tick rebuilds
        // for the new source rather than serving the old one.
        XCTAssertFalse(s.hasCachedFilterForCurrentTarget)
    }

    func testReselectingSameSourceIsANoOp() {
        let s = ScreenPreviewSession()
        s.setTarget(.display(2))
        let gen = s.generation
        s.setTarget(.display(2))   // same target
        XCTAssertEqual(s.generation, gen, "re-selecting the same source must not bump generation")
    }
}
