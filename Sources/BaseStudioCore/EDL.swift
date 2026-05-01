import CoreMedia
import Foundation

public typealias NodeID = String     // node-type id, e.g. "zoom"
public typealias InstanceID = String // node-instance id

/// The EDL — single source of truth for "what the video is" (PRD §2).
public struct Project: Codable, Sendable {
    public var sources: [SourceClip]
    public var videoTrack: VideoTrack
    public var nodeGraph: NodeGraph
    public var canvas: CanvasSpec
    public var timelineDuration: TimePoint
    public var zoomRegions: [ZoomRegion]
    public var captions: [Caption]

    public init(
        sources: [SourceClip],
        videoTrack: VideoTrack,
        nodeGraph: NodeGraph,
        canvas: CanvasSpec,
        timelineDuration: TimePoint,
        zoomRegions: [ZoomRegion] = [],
        captions: [Caption] = []
    ) {
        self.sources = sources
        self.videoTrack = videoTrack
        self.nodeGraph = nodeGraph
        self.canvas = canvas
        self.timelineDuration = timelineDuration
        self.zoomRegions = zoomRegions
        self.captions = captions
    }

    private enum CodingKeys: String, CodingKey {
        case sources, videoTrack, nodeGraph, canvas, timelineDuration, zoomRegions, captions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decode([SourceClip].self, forKey: .sources)
        videoTrack = try c.decode(VideoTrack.self, forKey: .videoTrack)
        nodeGraph = try c.decode(NodeGraph.self, forKey: .nodeGraph)
        canvas = try c.decode(CanvasSpec.self, forKey: .canvas)
        timelineDuration = try c.decode(TimePoint.self, forKey: .timelineDuration)
        zoomRegions = (try? c.decode([ZoomRegion].self, forKey: .zoomRegions)) ?? []
        captions = (try? c.decode([Caption].self, forKey: .captions)) ?? []
    }

    /// Build a `TimeMap` from this project's primary segment (trim) and zoom regions
    /// whose `speed` differs from 1.0. Used by preview, export, and audio mix.
    public func timeMap(primaryFirstPTS: CMTime) -> TimeMap {
        guard let seg = videoTrack.segments.first else {
            return TimeMap.identity(trimInSec: 0, trimOutSec: 0)
        }
        let trimInSec = max(0, CMTimeGetSeconds(CMTimeSubtract(seg.sourceIn.cmTime, primaryFirstPTS)))
        let trimOutSec = max(trimInSec, CMTimeGetSeconds(CMTimeSubtract(seg.sourceOut.cmTime, primaryFirstPTS)))
        let regions = zoomRegions.map { r in
            (startSec: r.timelineIn.seconds, endSec: r.timelineOut.seconds, speed: r.speed)
        }
        return TimeMap.make(
            trimInSec: trimInSec, trimOutSec: trimOutSec,
            speedRegions: regions
        )
    }
}

/// Reference to a recorded source file inside the project bundle.
public struct SourceClip: Codable, Sendable {
    public var id: String
    public var relativeMediaPath: String     // relative to bundle URL, e.g. "screen.mov"
    public var widthPx: Int
    public var heightPx: Int
    public var firstPTS: TimePoint           // host-clock anchor of first frame
    /// Sidecar streams attached to this source (cursor, clicks, audio_rms, …).
    public var sidecars: [SidecarRef]

    public init(
        id: String,
        relativeMediaPath: String,
        widthPx: Int, heightPx: Int,
        firstPTS: TimePoint,
        sidecars: [SidecarRef]
    ) {
        self.id = id
        self.relativeMediaPath = relativeMediaPath
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.firstPTS = firstPTS
        self.sidecars = sidecars
    }
}

public struct SidecarRef: Codable, Sendable {
    public var streamID: String              // logical id, e.g. "cursor", "clicks"
    public var relativePath: String          // e.g. "cursor.json"
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        case cursor          // CursorRecorder.Sidecar
        case clicks          // derived view of cursor.json clicks array
        case audioRMS
    }

    public init(streamID: String, relativePath: String, kind: Kind) {
        self.streamID = streamID
        self.relativePath = relativePath
        self.kind = kind
    }
}

public struct VideoTrack: Codable, Sendable {
    public var segments: [VideoSegment]
    public init(segments: [VideoSegment]) { self.segments = segments }
}

public struct VideoSegment: Codable, Sendable {
    public var sourceID: String
    public var sourceIn: TimePoint
    public var sourceOut: TimePoint
    public var timelineIn: TimePoint
    // SpeedCurve goes here in M4.

    public init(sourceID: String, sourceIn: TimePoint, sourceOut: TimePoint, timelineIn: TimePoint) {
        self.sourceID = sourceID
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.timelineIn = timelineIn
    }
}

/// Output canvas. Background nodes paint within these bounds.
public struct CanvasSpec: Codable, Sendable, Hashable {
    public var widthPx: Int
    public var heightPx: Int

    public init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
    }

    public static let landscape16x9 = CanvasSpec(widthPx: 1920, heightPx: 1080)
    public static let vertical9x16  = CanvasSpec(widthPx: 1080, heightPx: 1920)
    public static let square        = CanvasSpec(widthPx: 1080, heightPx: 1080)
    public static let landscape4x3  = CanvasSpec(widthPx: 1440, heightPx: 1080)

    public var label: String {
        switch (widthPx, heightPx) {
        case (1920, 1080): return "16:9"
        case (1080, 1920): return "9:16"
        case (1080, 1080): return "1:1"
        case (1440, 1080): return "4:3"
        default: return "\(widthPx)×\(heightPx)"
        }
    }

    public static let presets: [CanvasSpec] = [
        .landscape16x9, .vertical9x16, .square, .landscape4x3
    ]
}

/// Ordered chain of nodes (linear v1; DAG comes later if needed).
public struct NodeGraph: Codable, Sendable {
    public var nodes: [NodeInstance]
    public init(nodes: [NodeInstance]) { self.nodes = nodes }
}

public struct NodeInstance: Codable, Sendable {
    public var instanceID: InstanceID
    public var nodeType: NodeID
    public var bindings: [String: ParamBinding]   // param name → binding
    public var enabled: Bool

    public init(
        instanceID: InstanceID,
        nodeType: NodeID,
        bindings: [String: ParamBinding],
        enabled: Bool = true
    ) {
        self.instanceID = instanceID
        self.nodeType = nodeType
        self.bindings = bindings
        self.enabled = enabled
    }
}
