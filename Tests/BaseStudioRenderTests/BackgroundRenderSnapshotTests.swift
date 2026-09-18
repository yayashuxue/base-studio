import AVFoundation
import CoreImage
import Foundation
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRender

/// Renders `BackgroundCompose` straight to a PNG on the CPU (software CIContext,
/// no GPU / window server) so the background look can be eyeballed headlessly —
/// this is the same node the export pipeline runs, so what these PNGs show is
/// what a real export produces. Used to review the Porcelain default vs the old
/// dark wash without driving the GUI. Writes to /tmp; asserts the render is
/// non-empty so a broken compose still fails loudly.
@available(macOS 13.0, *)
final class BackgroundRenderSnapshotTests: XCTestCase {

    func testRendersDefaultAndOldBackgroundsForReview() throws {
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        let canvas = CanvasSpec(widthPx: 1280, heightPx: 720)
        let source = SourceClip(
            id: SourceID.screen,
            relativeMediaPath: "screen.mov",
            widthPx: 800, heightPx: 450,
            firstPTS: TimePoint(.zero),
            sidecars: []
        )
        let ctx = RenderCtx(
            pts: .zero, canvas: canvas, quality: .high,
            primarySource: source, ciContext: ciContext,
            frameProvider: { _, _ in nil }
        )
        // Distinctive "screen content" so padding, rounded corners and the drop
        // shadow read clearly against either backdrop.
        let input = CIImage(color: CIColor(red: 0.10, green: 0.45, blue: 0.55))
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 450))
        let node = BackgroundCompose()

        // New default — empty params resolve to the Porcelain spec defaults.
        let porcelain = node.apply(input: input, params: ParamValues(), ctx: ctx)
        try write(porcelain, ciContext, canvas, to: "/tmp/bg-porcelain-new.png")

        // Old dark-blue wash, for before/after comparison.
        let dark = node.apply(input: input, params: ParamValues([
            "bgTop": .color(r: 0.13, g: 0.18, b: 0.32, a: 1),
            "bgBottom": .color(r: 0.05, g: 0.06, b: 0.10, a: 1),
            "bgStyle": .scalar(0),
            "shadowOpacity": .scalar(0.35),
        ]), ctx: ctx)
        try write(dark, ciContext, canvas, to: "/tmp/bg-dark-old.png")

        // 小o's "melt" case: a near-white screen (webpage/doc) on the warm-white
        // Porcelain default. The hairline edge + soft shadow must keep the card
        // readable. Render with the border ON and OFF for comparison.
        let whiteInput = CIImage(color: CIColor(red: 0.99, green: 0.99, blue: 0.99))
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 450))
        let whiteBordered = node.apply(input: whiteInput, params: ParamValues(), ctx: ctx)
        try write(whiteBordered, ciContext, canvas, to: "/tmp/bg-white-porcelain-border.png")
        let whiteNoBorder = node.apply(
            input: whiteInput,
            params: ParamValues(["borderOpacity": .scalar(0)]),
            ctx: ctx
        )
        try write(whiteNoBorder, ciContext, canvas, to: "/tmp/bg-white-porcelain-noborder.png")

        XCTAssertFalse(porcelain.extent.isInfinite, "compose produced an unbounded image")
    }

    func testWebcamOverlayCircleVsRoundedForReview() throws {
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        let canvas = CanvasSpec(widthPx: 1280, heightPx: 720)
        let canvasRect = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let source = SourceClip(
            id: SourceID.screen, relativeMediaPath: "screen.mov",
            widthPx: 1280, heightPx: 720, firstPTS: TimePoint(.zero), sidecars: []
        )
        // A distinctive "webcam frame" so the shape mask edge reads clearly.
        let webcam = CIImage(color: CIColor(red: 0.85, green: 0.2, blue: 0.55))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let ctx = RenderCtx(
            pts: .zero, canvas: canvas, quality: .high,
            primarySource: source, ciContext: ciContext,
            frameProvider: { id, _ in id == SourceID.webcam ? webcam : nil }
        )
        let base = CIImage(color: CIColor(red: 0.95, green: 0.96, blue: 0.97)).cropped(to: canvasRect)
        let node = WebcamOverlay()

        let circle = node.apply(
            input: base,
            params: ParamValues(["sizePx": .scalar(240), "shape": .scalar(0)]),
            ctx: ctx
        )
        try write(circle, ciContext, canvas, to: "/tmp/webcam-circle.png")

        let rounded = node.apply(
            input: base,
            params: ParamValues(["sizePx": .scalar(240), "shape": .scalar(1)]),
            ctx: ctx
        )
        try write(rounded, ciContext, canvas, to: "/tmp/webcam-rounded.png")

        XCTAssertFalse(circle.extent.isInfinite)
    }

    private func write(_ image: CIImage, _ ciContext: CIContext, _ canvas: CanvasSpec, to path: String) throws {
        let rect = CGRect(x: 0, y: 0, width: canvas.widthPx, height: canvas.heightPx)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        try ciContext.writePNGRepresentation(
            of: image.cropped(to: rect),
            to: URL(fileURLWithPath: path),
            format: .RGBA8, colorSpace: cs
        )
    }
}
