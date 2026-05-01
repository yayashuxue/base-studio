import BaseStudioCore
import CoreGraphics
import CoreImage
import Foundation

/// Soft ripple at click points. The user-visible "click bubble" effect.
/// Bound to the same `clicks` stream as auto-zoom: the bubble's *radius* and
/// *opacity* are the EventDriven envelope value, the *position* is StreamBound
/// to the cursor stream sampled at the click PTS.
public struct ClickBubble: VideoNode {
    public init() {}

    public static let spec = NodeSpec(
        id: "click_bubble",
        domain: .video,
        paramSchema: [
            ParamSpec(name: "intensity", type: .scalar, defaultValue: .scalar(0)),
            ParamSpec(name: "position", type: .point2, defaultValue: .point2(x: -1000, y: -1000)),
            ParamSpec(name: "maxRadiusPx", type: .scalar, defaultValue: .scalar(120)),
        ]
    )

    public func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage {
        let intensity = params["intensity"]?.asScalar ?? 0
        if intensity <= 0.001 { return input }
        guard let (px, py) = params["position"]?.asPoint2 else { return input }
        let maxR = params["maxRadiusPx"]?.asScalar ?? 120
        let radius = max(8.0, intensity * maxR)
        let alpha = (1.0 - intensity) * 0.6 + 0.05

        let sprite = Self.bubbleSprite(radius: CGFloat(radius), alpha: CGFloat(alpha))
        let placed = sprite.transformed(by: CGAffineTransform(
            translationX: CGFloat(px) - sprite.extent.width / 2,
            y: CGFloat(py) - sprite.extent.height / 2
        ))
        return placed.composited(over: input).cropped(to: input.extent)
    }

    private static func bubbleSprite(radius: CGFloat, alpha: CGFloat) -> CIImage {
        let pixelScale: CGFloat = 2
        let size = Int((radius * 2 + 8) * pixelScale)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        let center = CGPoint(x: CGFloat(size) / (2 * pixelScale), y: CGFloat(size) / (2 * pixelScale))
        let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: alpha)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: outer)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: alpha * 0.25)
        ctx.fillEllipse(in: outer)

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(scaleX: 1.0 / pixelScale, y: 1.0 / pixelScale)
        )
    }
}
