import BaseStudioCore
import Foundation

/// The only "central" file (TECH_DESIGN §6). Adding a node = one new file under
/// `Nodes/` plus one entry here. The renderer, EDL serializer, and (eventually)
/// the inspector UI all look nodes up through this registry.
public enum NodeRegistry {

    public static let video: [NodeID: any VideoNode] = [
        Zoom.spec.id: Zoom(),
        CursorPaint.spec.id: CursorPaint(),
        ClickBubble.spec.id: ClickBubble(),
        BackgroundCompose.spec.id: BackgroundCompose(),
        WebcamOverlay.spec.id: WebcamOverlay(),
        CaptionOverlay.spec.id: CaptionOverlay(),
    ]

    public static func videoNode(_ id: NodeID) -> (any VideoNode)? { video[id] }
}
