import BaseStudioCore
import CoreImage
import CoreMedia
import Foundation

/// Pure renderer (PRD §5a). Same function for preview and export — they differ
/// only in scheduler. Inputs: EDL, pts, sources, quality. Output: a CIImage.
public enum Renderer {

    public struct Inputs {
        public let project: Project
        public let pts: CMTime                  // timeline time of this frame
        public let sidecarOffset: CMTime        // streamTime = pts + offset (used for trim)
        public let primarySource: SourceClip
        public let primaryFrame: CIImage
        public let sidecars: SidecarStreams
        public let quality: QualityTier
        public let ciContext: CIContext
        public let backgroundImage: CIImage?
        public let frameProvider: (String, CMTime) -> CIImage?

        public init(
            project: Project,
            pts: CMTime,
            sidecarOffset: CMTime = .zero,
            primarySource: SourceClip,
            primaryFrame: CIImage,
            sidecars: SidecarStreams,
            quality: QualityTier,
            ciContext: CIContext,
            backgroundImage: CIImage? = nil,
            frameProvider: @escaping (String, CMTime) -> CIImage?
        ) {
            self.project = project
            self.pts = pts
            self.sidecarOffset = sidecarOffset
            self.primarySource = primarySource
            self.primaryFrame = primaryFrame
            self.sidecars = sidecars
            self.quality = quality
            self.ciContext = ciContext
            self.backgroundImage = backgroundImage
            self.frameProvider = frameProvider
        }
    }

    public static func render(_ inputs: Inputs) -> CIImage {
        // Resolve the active caption (if any) at this PTS. Captions live in
        // the Project model; the resolver is a pure function of (project, t).
        let captionText = CaptionResolver.active(at: inputs.pts, captions: inputs.project.captions)
        let ctx = RenderCtx(
            pts: inputs.pts,
            canvas: inputs.project.canvas,
            quality: inputs.quality,
            primarySource: inputs.primarySource,
            ciContext: inputs.ciContext,
            captionTextForFrame: captionText,
            backgroundImage: inputs.backgroundImage,
            frameProvider: inputs.frameProvider
        )

        var image = inputs.primaryFrame

        let streamTime = CMTimeAdd(inputs.pts, inputs.sidecarOffset)
        let regionResolved = ZoomRegionResolver.resolved(
            at: inputs.pts, regions: inputs.project.zoomRegions
        )

        for inst in inputs.project.nodeGraph.nodes {
            // Background off: the frame still has to land in canvas space —
            // later nodes (webcam overlay) and the output assume it. Without
            // this the screen sat 1:1 in the bottom-left corner, cropped
            // (julie: "remove 背景视觉会偏").
            if inst.nodeType == "background_compose", !inst.enabled {
                image = fitToCanvas(image, canvas: inputs.project.canvas)
                continue
            }
            guard inst.enabled, let node = NodeRegistry.videoNode(inst.nodeType) else { continue }
            var resolved = ParamResolver.resolve(
                bindings: inst.bindings, at: inputs.pts,
                streamTime: streamTime, sidecars: inputs.sidecars
            )
            // Region override: zoom regions take precedence over any binding for `zoom` node.
            if inst.nodeType == "zoom" {
                if let r = regionResolved {
                    resolved.values["scale"] = .scalar(r.scale)
                    if r.followCursor {
                        // Cursor-bound center: replace with current cursor position from sidecars.
                        if let bind = inst.bindings["center"] {
                            resolved.values["center"] = ParamResolver.resolveOne(
                                binding: bind, at: inputs.pts,
                                streamTime: streamTime, sidecars: inputs.sidecars
                            )
                        }
                    } else if let fc = r.fixedCenter {
                        resolved.values["center"] = .point2(x: fc.x, y: fc.y)
                    }
                } else {
                    resolved.values["scale"] = .scalar(1.0)
                }
            }
            image = node.apply(input: image, params: resolved, ctx: ctx)
        }

        return image
    }

    /// Scale `image` to fit the canvas, centred, over black.
    static func fitToCanvas(_ image: CIImage, canvas: CanvasSpec) -> CIImage {
        let cw = CGFloat(canvas.widthPx), ch = CGFloat(canvas.heightPx)
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let k = min(cw / e.width, ch / e.height)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: (cw - e.width * k) / 2, y: (ch - e.height * k) / 2))
        let rect = CGRect(x: 0, y: 0, width: cw, height: ch)
        return placed.composited(over: CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
    }
}
