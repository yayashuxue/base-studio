import CoreImage
import CoreMedia
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRender

/// Preview renders at a smaller size (renderScale) with pixel params scaled
/// — the picture must match the full-size render shrunk, not change layout.
final class RenderScaleTests: XCTestCase {
    func testHalfScaleMatchesFullRenderShrunk() throws {
        let w = 1512, h = 982
        // A recognisable source: left half red, right half blue.
        let src = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: w / 2, height: h))
            .composited(over: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)))
        let screen = SourceClip(id: SourceID.screen, relativeMediaPath: "screen.mov", widthPx: w, heightPx: h,
                                firstPTS: TimePoint(.zero), sidecars: [])
        let bg = NodeInstance(instanceID: "bg", nodeType: "background_compose", bindings: [:], enabled: true)
        let cursor = NodeInstance(instanceID: "c", nodeType: "cursor_paint", bindings: [
            "position": .constant(.point2(x: 700, y: 500)), "scale": .constant(.scalar(2.4)),
        ], enabled: true)
        let project = Project(sources: [screen], videoTrack: VideoTrack(segments: []),
                              nodeGraph: NodeGraph(nodes: [cursor, bg]), canvas: CanvasSpec(widthPx: 1920, heightPx: 1080),
                              timelineDuration: TimePoint(.zero))
        let ctx = CIContext()
        func render(_ k: Double) -> CIImage {
            var i = Renderer.Inputs(project: project, pts: .zero, primarySource: screen, primaryFrame: src,
                                    sidecars: SidecarStreams(), quality: .standard, ciContext: ctx,
                                    frameProvider: { _, _ in nil })
            i.renderScale = k
            return Renderer.render(i)
        }
        let full = render(1).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let half = render(0.5)
        XCTAssertEqual(half.extent.width, 960, accuracy: 1)
        XCTAssertEqual(half.extent.height, 540, accuracy: 1)
        // Compare on a coarse grid (edges differ by resampling only).
        var worst = 0
        for gx in stride(from: 20, to: 960, by: 47) {
            for gy in stride(from: 20, to: 540, by: 31) {
                func px(_ img: CIImage) -> [UInt8] {
                    var p = [UInt8](repeating: 0, count: 4)
                    ctx.render(img, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: gx, y: gy, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    return p
                }
                let a = px(full), b = px(half)
                let d = (0..<3).map { abs(Int(a[$0]) - Int(b[$0])) }.max()!
                if d > 40 { print("DIFF at \(gx),\(gy): full \(a) half \(b)") }
                worst = max(worst, d)
            }
        }
        XCTAssertLessThan(worst, 40, "half-scale render differs from full render shrunk (max channel diff \(worst))")
    }
}
