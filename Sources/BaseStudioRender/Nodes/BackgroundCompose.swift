import BaseStudioCore
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Final compositing stage: paints the canvas background, then places the input
/// image (the polished screen content) inside it with padding, rounded corners,
/// and a drop shadow. Output extent = canvas size.
public struct BackgroundCompose: VideoNode {
    public init() {}

    public static let spec = NodeSpec(
        id: "background_compose",
        domain: .video,
        paramSchema: [
            ParamSpec(name: "paddingPx", type: .scalar, defaultValue: .scalar(80)),
            ParamSpec(name: "cornerRadiusPx", type: .scalar, defaultValue: .scalar(24)),
            ParamSpec(name: "shadowRadiusPx", type: .scalar, defaultValue: .scalar(40)),
            ParamSpec(name: "shadowOpacity", type: .scalar, defaultValue: .scalar(0.35)),
            ParamSpec(name: "bgTop", type: .color, defaultValue: .color(r: 0.13, g: 0.18, b: 0.32, a: 1)),
            ParamSpec(name: "bgBottom", type: .color, defaultValue: .color(r: 0.05, g: 0.06, b: 0.10, a: 1)),
            // 0 = linear (top→bottom), 1 = radial, 2 = diagonal mesh.
            ParamSpec(name: "bgStyle", type: .scalar, defaultValue: .scalar(0)),
        ]
    )

    public func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage {
        let padding = CGFloat(params["paddingPx"]?.asScalar ?? 80)
        let corner = CGFloat(params["cornerRadiusPx"]?.asScalar ?? 24)
        let shadowR = CGFloat(params["shadowRadiusPx"]?.asScalar ?? 40)
        let shadowOp = CGFloat(params["shadowOpacity"]?.asScalar ?? 0.35)

        let canvasW = CGFloat(ctx.canvas.widthPx)
        let canvasH = CGFloat(ctx.canvas.heightPx)
        let canvasRect = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)

        // 1. Background gradient (style: linear / radial / diagonal mesh).
        let style = Int(params["bgStyle"]?.asScalar ?? 0)
        let topC = params["bgTop"]?.asColor ?? (0.13, 0.18, 0.32, 1)
        let botC = params["bgBottom"]?.asColor ?? (0.05, 0.06, 0.10, 1)
        let bg: CIImage
        switch style {
        case 1: bg = radialGradient(top: topC, bottom: botC, in: canvasRect)
        case 2: bg = diagonalMesh(top: topC, bottom: botC, in: canvasRect)
        default: bg = gradient(top: topC, bottom: botC, in: canvasRect)
        }

        // 2. Fit input into (canvas - 2*padding) preserving aspect.
        let avail = canvasRect.insetBy(dx: padding, dy: padding)
        let inExtent = input.extent
        let scale = min(avail.width / inExtent.width, avail.height / inExtent.height)
        let placedW = inExtent.width * scale
        let placedH = inExtent.height * scale
        let placedRect = CGRect(
            x: (canvasW - placedW) / 2,
            y: (canvasH - placedH) / 2,
            width: placedW, height: placedH
        )

        // Scale and translate the input.
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: placedRect.minX, y: placedRect.minY)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -inExtent.minX, y: -inExtent.minY)
        let scaledInput = input.transformed(by: t).cropped(to: placedRect)

        // 3. Rounded-corner mask matching placedRect.
        let mask = roundedRectMask(rect: placedRect, radius: corner, canvas: canvasRect)
        let maskedInput = scaledInput.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: canvasRect),
            kCIInputMaskImageKey: mask,
        ])

        // 4. Soft drop shadow under the masked input.
        let shadow = mask
            .applyingGaussianBlur(sigma: Double(shadowR))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadowOp),
            ])
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                    .cropped(to: canvasRect),
            ])

        // 5. Compose: bg + shadow + maskedInput.
        let withShadow = shadow.composited(over: bg)
        let result = maskedInput.composited(over: withShadow)
        return result.cropped(to: canvasRect)
    }

    // MARK: - helpers

    private func gradient(
        top: (Double, Double, Double, Double),
        bottom: (Double, Double, Double, Double),
        in rect: CGRect
    ) -> CIImage {
        let f = CIFilter.linearGradient()
        f.point0 = CGPoint(x: rect.midX, y: rect.maxY)
        f.point1 = CGPoint(x: rect.midX, y: rect.minY)
        f.color0 = CIColor(red: top.0, green: top.1, blue: top.2, alpha: top.3)
        f.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: bottom.3)
        return (f.outputImage ?? CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
    }

    private func radialGradient(
        top: (Double, Double, Double, Double),
        bottom: (Double, Double, Double, Double),
        in rect: CGRect
    ) -> CIImage {
        let f = CIFilter.radialGradient()
        f.center = CGPoint(x: rect.midX, y: rect.midY * 1.1)
        f.radius0 = 0
        f.radius1 = Float(max(rect.width, rect.height) * 0.7)
        f.color0 = CIColor(red: top.0, green: top.1, blue: top.2, alpha: top.3)
        f.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: bottom.3)
        return (f.outputImage ?? CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
    }

    /// Soft diagonal mesh: two radial blobs in opposite corners colored by top/bottom,
    /// composited over the bottom color. Costless approximation of mesh gradients.
    private func diagonalMesh(
        top: (Double, Double, Double, Double),
        bottom: (Double, Double, Double, Double),
        in rect: CGRect
    ) -> CIImage {
        let base = CIImage(color: CIColor(
            red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1
        )).cropped(to: rect)

        let blob1F = CIFilter.radialGradient()
        blob1F.center = CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.2)
        blob1F.radius0 = 0
        blob1F.radius1 = Float(rect.width * 0.55)
        blob1F.color0 = CIColor(red: top.0, green: top.1, blue: top.2, alpha: 0.95)
        blob1F.color1 = CIColor(red: top.0, green: top.1, blue: top.2, alpha: 0)
        let blob1 = (blob1F.outputImage ?? base).cropped(to: rect)

        let blob2F = CIFilter.radialGradient()
        blob2F.center = CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.25)
        blob2F.radius0 = 0
        blob2F.radius1 = Float(rect.width * 0.5)
        blob2F.color0 = CIColor(red: bottom.0 * 1.6, green: bottom.1 * 1.4,
                                blue: bottom.2 * 1.5, alpha: 0.55)
        blob2F.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 0)
        let blob2 = (blob2F.outputImage ?? base).cropped(to: rect)

        return blob2.composited(over: blob1.composited(over: base)).cropped(to: rect)
    }

    private func roundedRectMask(rect: CGRect, radius: CGFloat, canvas: CGRect) -> CIImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let w = Int(canvas.width), h = Int(canvas.height)
        guard let bctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return CIImage.empty() }
        bctx.setFillColor(gray: 1, alpha: 1)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        bctx.addPath(path)
        bctx.fillPath()
        guard let cg = bctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }
}
