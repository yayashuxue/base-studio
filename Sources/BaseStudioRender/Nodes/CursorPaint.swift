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
        let dim = Int((radius * 2 + 4) * pixelScale)
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
        let blurred = raw.applyingGaussianBlur(sigma: Double(radius) * 0.4)
        let trimmed = blurred.cropped(to: raw.extent)
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

        let nsImage = NSCursor.arrow.image
        guard let cg = renderNSImageToCG(nsImage, oversampling: 3) else {
            return CIImage.empty()
        }
        // The CGImage is at 3x resolution; we then scale by `scale / 3` for final size.
        let s = scale / 3.0
        let img = CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(scaleX: s, y: s)
        )
        cachedSprites.setObject(img, forKey: key)
        return img
    }

    private static func renderNSImageToCG(_ image: NSImage, oversampling: Int = 3) -> CGImage? {
        let size = image.size
        let w = Int(size.width * CGFloat(oversampling))
        let h = Int(size.height * CGFloat(oversampling))
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = nsCtx
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.current = prev
        return ctx.makeImage()
    }
}
