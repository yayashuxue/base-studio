import BaseStudioCore
import CoreImage
import CoreMedia
import Foundation

/// Quality tier — controls *how* an effect is computed, never *what* (PRD §5a).
public enum QualityTier: String, Sendable {
    case draft       // fast, lower-quality interpolation; for live preview scrubbing
    case standard    // default
    case high        // export quality; preview at this tier == export output
}

/// What a node tells the renderer about itself.
public struct NodeSpec: Sendable {
    public let id: NodeID
    public let domain: Domain
    public let paramSchema: [ParamSpec]
    public init(id: NodeID, domain: Domain, paramSchema: [ParamSpec]) {
        self.id = id
        self.domain = domain
        self.paramSchema = paramSchema
    }
}

public enum Domain: String, Sendable { case video, audio }

public struct ParamSpec: Sendable {
    public let name: String
    public let type: ParamType
    public let defaultValue: ParamValue
    public init(name: String, type: ParamType, defaultValue: ParamValue) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }
}

public enum ParamType: String, Sendable {
    case scalar, point2, color, bool
}

/// Context handed to a node for one frame render. Pure inputs only.
public final class RenderCtx {
    public let pts: CMTime                   // timeline time of this frame
    public let canvas: CanvasSpec
    public let quality: QualityTier
    public let primarySource: SourceClip     // the screen capture clip for now
    public let ciContext: CIContext
    public let captionTextForFrame: String?
    /// Pre-loaded CIImage for `Project.backgroundImageRel`. nil = use the
    /// gradient preset. Lifted into `RenderCtx` so the render pass doesn't
    /// hit disk per frame; `EditorState` / `ExportPipeline` are responsible
    /// for caching the load.
    public let backgroundImage: CIImage?
    private let frameProvider: (String, CMTime) -> CIImage?

    public init(
        pts: CMTime,
        canvas: CanvasSpec,
        quality: QualityTier,
        primarySource: SourceClip,
        ciContext: CIContext,
        captionTextForFrame: String? = nil,
        backgroundImage: CIImage? = nil,
        frameProvider: @escaping (String, CMTime) -> CIImage?
    ) {
        self.pts = pts
        self.canvas = canvas
        self.quality = quality
        self.primarySource = primarySource
        self.ciContext = ciContext
        self.captionTextForFrame = captionTextForFrame
        self.backgroundImage = backgroundImage
        self.frameProvider = frameProvider
    }

    /// Frame from any source clip at any host-clock PTS. Used by multi-source nodes
    /// (e.g. WebcamOverlay reads webcam frames; primary chain reads screen frames).
    public func sourceFrame(_ sourceID: String, at pts: CMTime) -> CIImage? {
        frameProvider(sourceID, pts)
    }
}

/// A node is a pure function from (input frame, params, context) → output frame.
/// Adding a feature usually means adding a Node: see TECH_DESIGN §8.
public protocol VideoNode: Sendable {
    static var spec: NodeSpec { get }
    func apply(input: CIImage, params: ParamValues, ctx: RenderCtx) -> CIImage
}
