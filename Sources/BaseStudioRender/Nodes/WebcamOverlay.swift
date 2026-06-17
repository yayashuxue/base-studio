import BaseStudioCore
import CoreGraphics
import CoreImage
import Foundation

/// Composites a circular webcam frame onto the canvas (typically corner-pinned).
/// The webcam frame is fetched from a *secondary source* via `RenderCtx.sourceFrame`.
/// This is the multi-source case the architecture was designed to handle from day
/// one (TECH_DESIGN §1) — adding it requires no engine changes.
public struct WebcamOverlay: VideoNode {
    public init() {}

    public static let spec = NodeSpec(
        id: "webcam_overlay",
        domain: .video,
        paramSchema: [
            ParamSpec(name: "sourceID", type: .scalar, defaultValue: .scalar(0)), // unused; passed via constants
            ParamSpec(name: "sizePx", type: .scalar, defaultValue: .scalar(220)),
            ParamSpec(name: "marginPx", type: .scalar, defaultValue: .scalar(80)),
            ParamSpec(name: "corner", type: .scalar, defaultValue: .scalar(3)), // 0..3 = TL,TR,BL,BR
            ParamSpec(name: "visible", type: .bool, defaultValue: .bool(true)),
        ]
    )

    public func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage {
        guard params["visible"]?.asBool ?? true else { return input }
        guard let webcam = ctx.sourceFrame(SourceID.webcam, at: ctx.pts) else { return input }

        let size = CGFloat(params["sizePx"]?.asScalar ?? 220)
        let margin = CGFloat(params["marginPx"]?.asScalar ?? 80)
        let cornerIdx = Int(params["corner"]?.asScalar ?? 3)

        // 1. Square-crop the webcam frame to its short side, centered.
        let we = webcam.extent
        let s = min(we.width, we.height)
        let cropRect = CGRect(
            x: we.midX - s / 2, y: we.midY - s / 2, width: s, height: s
        )
        let cropped = webcam.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        // 2. Scale to target size.
        let scale = size / s
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))

        // 3. Circular mask.
        let mask = circleMask(diameter: size)
        let masked = scaled.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear)
                .cropped(to: CGRect(x: 0, y: 0, width: size, height: size)),
            kCIInputMaskImageKey: mask,
        ])

        // 4. Place at chosen corner of the input canvas.
        let canvas = input.extent
        let pos: CGPoint
        switch cornerIdx {
        case 0: pos = CGPoint(x: canvas.minX + margin, y: canvas.maxY - margin - size) // TL
        case 1: pos = CGPoint(x: canvas.maxX - margin - size, y: canvas.maxY - margin - size) // TR
        case 2: pos = CGPoint(x: canvas.minX + margin, y: canvas.minY + margin) // BL
        default: pos = CGPoint(x: canvas.maxX - margin - size, y: canvas.minY + margin) // BR
        }
        let placed = masked.transformed(by: CGAffineTransform(translationX: pos.x, y: pos.y))

        // 5. Soft shadow under the circle.
        let shadow = mask
            .applyingGaussianBlur(sigma: 18)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
            ])
            .transformed(by: CGAffineTransform(translationX: pos.x, y: pos.y - 6))

        return placed.composited(over: shadow.composited(over: input))
            .cropped(to: input.extent)
    }

    private func circleMask(diameter: CGFloat) -> CIImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let n = Int(diameter)
        guard let bctx = CGContext(
            data: nil, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return CIImage.empty() }
        bctx.setFillColor(gray: 1, alpha: 1)
        bctx.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        guard let cg = bctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }
}
