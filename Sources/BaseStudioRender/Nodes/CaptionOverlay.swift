import AppKit
import BaseStudioCore
import CoreGraphics
import CoreImage
import Foundation

/// Renders a caption text overlay near the bottom of the canvas. Text is
/// resolved from `params["text"]` (a stringified scalar passes through; non-text
/// param types fall back to nothing). Renderer feeds the active caption text in.
public struct CaptionOverlay: VideoNode {
    public init() {}

    public static let spec = NodeSpec(
        id: "caption_overlay",
        domain: .video,
        paramSchema: [
            ParamSpec(name: "visible", type: .bool, defaultValue: .bool(true)),
            ParamSpec(name: "fontSize", type: .scalar, defaultValue: .scalar(56)),
            ParamSpec(name: "marginPx", type: .scalar, defaultValue: .scalar(120)),
        ]
    )

    public func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage {
        guard params["visible"]?.asBool ?? true,
              let text = ctx.captionTextForFrame, !text.isEmpty
        else { return input }
        let fontSize = CGFloat(params["fontSize"]?.asScalar ?? 56)
        let bottomMargin = CGFloat(params["marginPx"]?.asScalar ?? 120)

        let canvas = input.extent
        let sprite = Self.renderCaption(
            text: text, canvasWidth: canvas.width, fontSize: fontSize
        )
        let x = (canvas.width - sprite.extent.width) / 2
        let y = bottomMargin
        let placed = sprite.transformed(by: CGAffineTransform(
            translationX: canvas.minX + x, y: canvas.minY + y
        ))
        return placed.composited(over: input).cropped(to: input.extent)
    }

    private static let cache = NSCache<NSString, CIImage>()

    private static func renderCaption(
        text: String, canvasWidth: CGFloat, fontSize: CGFloat
    ) -> CIImage {
        let key = "\(text)_\(Int(canvasWidth))_\(Int(fontSize))" as NSString
        if let s = cache.object(forKey: key) { return s }

        let pixelScale: CGFloat = 2
        let maxTextWidth = canvasWidth * 0.8
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textBox = attr.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padding: CGFloat = fontSize * 0.4
        let boxW = ceil(textBox.width) + padding * 2
        let boxH = ceil(textBox.height) + padding * 1.6
        let pxW = Int(boxW * pixelScale), pxH = Int(boxH * pixelScale)
        guard pxW > 0, pxH > 0 else { return CIImage.empty() }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        ctx.scaleBy(x: pixelScale, y: pixelScale)

        // Soft black pill background.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.65)
        let pill = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: boxW, height: boxH),
            cornerWidth: boxH / 2, cornerHeight: boxH / 2,
            transform: nil
        )
        ctx.addPath(pill); ctx.fillPath()

        // Draw text — Cocoa text rendering needs an NSGraphicsContext with flipped=false.
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = nsCtx
        attr.draw(with: CGRect(
            x: padding, y: padding * 0.8,
            width: boxW - padding * 2, height: boxH - padding * 0.8
        ), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.current = prev

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let img = CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(scaleX: 1.0 / pixelScale, y: 1.0 / pixelScale)
        )
        cache.setObject(img, forKey: key)
        return img
    }
}
