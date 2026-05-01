import BaseStudioCore
import CoreImage
import Foundation

/// Zooms the input frame by `scale` toward `center` (in input-image pixel coords,
/// CIImage convention: bottom-left origin). Output extent matches input extent —
/// the zoomed image is cropped to the original frame.
///
/// One node, three UX features (TECH_DESIGN §3):
///   - manual zoom        ⇢ scale.keyframed, center.keyframed
///   - follow-mouse zoom  ⇢ center.streamBound("cursor")
///   - auto-zoom on click ⇢ scale.eventDriven("clicks", envelope: …),
///                          center.streamBound("cursor")
public struct Zoom: VideoNode {
    public init() {}

    public static let spec = NodeSpec(
        id: "zoom",
        domain: .video,
        paramSchema: [
            ParamSpec(name: "scale", type: .scalar, defaultValue: .scalar(1.0)),
            ParamSpec(name: "center", type: .point2, defaultValue: .point2(x: 0, y: 0)),
        ]
    )

    public func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage {
        let scale = max(1.0, params["scale"]?.asScalar ?? 1.0)
        let extent = input.extent
        let (cx, cy) = params["center"]?.asPoint2 ?? (extent.midX, extent.midY)

        // Translate so that (cx, cy) is at the origin, scale, then translate back to
        // the same point in the output frame so the cursor sits where it was.
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: cx, y: cy)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -cx, y: -cy)

        let zoomed = input.transformed(by: t)
        return zoomed.cropped(to: extent)
    }
}
