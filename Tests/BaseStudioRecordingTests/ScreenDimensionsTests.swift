import XCTest
@testable import BaseStudioRecording

/// Regression tests for the screen-capture dimension math that fixed the
/// half-resolution recording bug (screen.mov came out 1512×982 on a 14" Retina
/// MBP whose framebuffer is 3024×1964, because SCDisplay.width is POINTS on
/// macOS 14.6.1). `clampToEncoderLimit` is the pure guard that keeps full
/// resolution while never re-introducing the -12785 / 0-byte VideoToolbox
/// blowup the old code worried about. It needs no display/GPU, so it's a fast
/// headless regression net.
@available(macOS 13.0, *)
final class ScreenDimensionsTests: XCTestCase {

    func testNativeRetinaPassesThroughUnclampedAtGeneralLimit() {
        // At the general 4096 encoder limit, 3024×1964 survives unchanged.
        let (w, h) = ScreenRecorder.clampToEncoderLimit(3024, 1964)
        XCTAssertEqual(w, 3024)
        XCTAssertEqual(h, 1964)
    }

    func testScreenCaptureCapsNativeRetinaForReliability() {
        // Real screen capture uses the conservative screenCaptureMaxDimension
        // (not the raw 4096) because full 3024×1964 regressed recordings to
        // -12785 mid-record. 3024×1964 must clamp to <= that ceiling, aspect
        // preserved, even dims.
        let cap = ScreenRecorder.screenCaptureMaxDimension
        XCTAssertLessThanOrEqual(cap, 2048, "screen cap should stay conservative")
        let (w, h) = ScreenRecorder.clampToEncoderLimit(3024, 1964, maxDimension: cap)
        XCTAssertEqual(max(w, h), cap)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
        // Still a real improvement over the old logical 1512 width.
        XCTAssertGreaterThan(w, 1512)
        // Aspect preserved.
        XCTAssertEqual(Double(w) / Double(h), 3024.0 / 1964.0, accuracy: 0.01)
    }

    func testOddDimensionsRoundedToEven() {
        // H.264 requires even dimensions; an odd input must be rounded down.
        let (w, h) = ScreenRecorder.clampToEncoderLimit(1921, 1081)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
        XCTAssertEqual(w, 1920)
        XCTAssertEqual(h, 1080)
    }

    func testOversizeClampedProportionallyPreservingAspect() {
        // A hypothetical doubled dimension (the old ×scale-on-already-pixels
        // mistake: 3024×2 = 6048) must clamp to the 4096 long edge WITHOUT
        // distorting aspect — that's what avoids the -12785 encoder failure.
        let inW = 6048, inH = 3928
        let (w, h) = ScreenRecorder.clampToEncoderLimit(inW, inH)
        XCTAssertLessThanOrEqual(max(w, h), 4096)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
        // Aspect ratio preserved within one even-rounding step.
        let inAspect = Double(inW) / Double(inH)
        let outAspect = Double(w) / Double(h)
        XCTAssertEqual(outAspect, inAspect, accuracy: 0.01)
        // Long edge actually clamped to the ceiling.
        XCTAssertEqual(max(w, h), 4096)
    }

    func testTallDisplayClampsOnHeight() {
        // Portrait/rotated display: the long edge is the height. Clamp must act
        // on whichever edge is longer, not always width.
        let (w, h) = ScreenRecorder.clampToEncoderLimit(3928, 6048)
        XCTAssertLessThanOrEqual(max(w, h), 4096)
        XCTAssertEqual(max(w, h), 4096)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
    }

    func testDegenerateInputClampedToMinimumEven() {
        // Never emit a 0/1px dimension — the encoder needs at least 2×2.
        let (w, h) = ScreenRecorder.clampToEncoderLimit(0, 1)
        XCTAssertGreaterThanOrEqual(w, 2)
        XCTAssertGreaterThanOrEqual(h, 2)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
    }
}
