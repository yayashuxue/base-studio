import AppKit
import BaseStudioCore
import CoreGraphics
import CoreImage
import Foundation

/// Draws the cursor sprite on top of the input frame at the position resolved
/// from the cursor sidecar stream. v1 cursor: simple white-arrow stand-in.
public struct CursorPaint: VideoNode {
    public init() {}

    public static let spec = NodeSpec(
        id: "cursor_paint",
        domain: .video,
        paramSchema: [
            ParamSpec(name: "position", type: .point2, defaultValue: .point2(x: -1000, y: -1000)),
            ParamSpec(name: "scale", type: .scalar, defaultValue: .scalar(1.0)),
            ParamSpec(name: "visible", type: .bool, defaultValue: .bool(true)),
            ParamSpec(name: "highlightAlpha", type: .scalar, defaultValue: .scalar(0.0)),
            ParamSpec(name: "highlightRadius", type: .scalar, defaultValue: .scalar(36)),
        ]
    )

    public func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage {
        guard params["visible"]?.asBool ?? true else { return input }
        guard let (px, py) = params["position"]?.asPoint2 else { return input }
        let scale = params["scale"]?.asScalar ?? 1.0
        let highlightAlpha = params["highlightAlpha"]?.asScalar ?? 0
        let highlightRadius = params["highlightRadius"]?.asScalar ?? 36

        var canvas = input

        // Optional always-on soft highlight behind the cursor.
        if highlightAlpha > 0.001 {
            let halo = Self.haloSprite(radius: CGFloat(highlightRadius), alpha: CGFloat(highlightAlpha))
            let placedHalo = halo.transformed(by: CGAffineTransform(
                translationX: CGFloat(px) - halo.extent.width / 2,
                y: CGFloat(py) - halo.extent.height / 2
            ))
            canvas = placedHalo.composited(over: canvas).cropped(to: input.extent)
        }

        let sprite = Self.cursorSprite(scale: CGFloat(scale))
        let placed = sprite.transformed(by: CGAffineTransform(
            translationX: CGFloat(px),
            y: CGFloat(py) - sprite.extent.height
        ))
        return placed.composited(over: canvas).cropped(to: input.extent)
    }

    /// Soft white halo behind the cursor — Screen Studio's "always-on" highlight.
    private static let haloCache = NSCache<NSString, CIImage>()
    static func haloSprite(radius: CGFloat, alpha: CGFloat) -> CIImage {
        let key = "\(Int(radius))_\(Int(alpha * 100))" as NSString
        if let s = haloCache.object(forKey: key) { return s }
        let pixelScale: CGFloat = 2
        // Room for the blur to fade out (3σ, σ = 0.4 r) inside the image:
        // the canvas used to end at the circle, so the glow was cut off in a
        // visible square around the cursor (julie: "a square mosaic").
        let pad = radius * 1.3
        let dim = Int((radius * 2 + pad * 2) * pixelScale)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        let cx = CGFloat(dim) / (2 * pixelScale)
        let cy = cx
        let outer = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: alpha * 0.4)
        ctx.fillEllipse(in: outer)
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let raw = CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(scaleX: 1.0 / pixelScale, y: 1.0 / pixelScale)
        )
        // Soft blur for a gradient halo edge.
        // Rasterized: a lazily-evaluated blur re-ran on every frame.
        let trimmed = RasterCache.image("halo2|\(key)") {
            raw.applyingGaussianBlur(sigma: Double(radius) * 0.4).cropped(to: raw.extent)
        }
        haloCache.setObject(trimmed, forKey: key)
        return trimmed
    }

    // MARK: - sprite

    private static let cachedSprites = NSCache<NSNumber, CIImage>()

    /// Native macOS cursor: render `NSCursor.arrow.image` to a high-res bitmap and
    /// scale to the requested user-facing scale. Looks identical to the system cursor.
    static func cursorSprite(scale: CGFloat) -> CIImage {
        let key = NSNumber(value: Double(scale))
        if let s = cachedSprites.object(forKey: key) { return s }
        guard let cg = drawArrow(oversampling: 3) else { return CIImage.empty() }
        // Drawn at 3×; scale by `scale / 3` for the final size.
        let s = scale / 3.0
        let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: s, y: s))
        cachedSprites.setObject(img, forKey: key)
        return img
    }

    /// The classic arrow, drawn as a vector (black, white outline), tip at the
    /// sprite's top-left. `NSCursor.arrow.image` is 0×0 on current macOS, so
    /// the sprite came out empty and no cursor was ever drawn (julie, 11/8).
    static func drawArrow(oversampling: Int) -> CGImage? {
        // Arrow outline in points, y down from the tip.
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 18.8), (7, 12), (12, 12)]
        let pad: CGFloat = 1.5
        let w: CGFloat = 12 + pad * 2, h: CGFloat = 20 + pad * 2
        let k = CGFloat(oversampling)
        guard let ctx = CGContext(
            data: nil, width: Int(w * k), height: Int(h * k), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: k, y: k)
        let path = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let q = CGPoint(x: p.0 + pad, y: h - (p.1 + pad))   // flip to bottom-left origin
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2.0)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        return ctx.makeImage()
    }
}
