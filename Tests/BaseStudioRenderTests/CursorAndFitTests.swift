import CoreImage
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRender

/// julie 11/8: no cursor in the video, and the picture slid off-centre with
/// the background removed.
final class CursorAndFitTests: XCTestCase {

    func testCursorSpriteIsNotEmpty() {
        // NSCursor.arrow.image is 0×0 on current macOS; the sprite was empty.
        let e = CursorPaint.cursorSprite(scale: 2.4).extent
        XCTAssertTrue(e.width > 20 && e.height > 30 && e.width.isFinite, "sprite extent \(e)")
    }

    func testCursorScaleComesFromTheRecordedFrame() {
        // Recorded at 1512 px on a 1512 pt Retina display: 1 px per point,
        // although the display's backing scale (pointScale) is 2.
        let meta = RecordingMetadata(
            displayID: 1, widthPx: 1512, heightPx: 982, pointScale: 2,
            displayOriginXPt: 0, displayOriginYPt: 0, displayWidthPt: 1512, displayHeightPt: 982,
            firstVideoPTS: TimePoint(.zero), lastVideoPTS: TimePoint(.zero)
        )
        XCTAssertEqual(meta.pixelsPerPoint, 1.0)
    }

    func testBackgroundOffFitsAndCentresTheScreen() {
        let screen = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let out = Renderer.fitToCanvas(screen, canvas: CanvasSpec(widthPx: 1920, heightPx: 1080))
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // 1080 / 982 → 1663 px wide, centred: ~128 px black each side.
        let ctx = CIContext()
        func px(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            var p = [UInt8](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
            return p[0]
        }
        XCTAssertEqual(px(60, 540), 0)       // left bar
        XCTAssertEqual(px(1860, 540), 0)     // right bar
        XCTAssertEqual(px(960, 540), 255)    // screen in the middle
        XCTAssertEqual(px(960, 5), 255)      // full height
    }
}
