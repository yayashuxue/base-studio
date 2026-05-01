import BaseStudioCore
import CoreMedia
import Foundation

/// Builds a default `Project` from a recorded `ProjectBundle`. This is the
/// "Polish" path: read recording metadata, instantiate the standard node graph
/// (cursor + click bubble + auto-zoom + gradient bg + optional webcam), bind
/// params to the right sources. No editing UI required.
public enum PolishPreset {

    public static func makeProject(bundle: ProjectBundle) throws -> Project {
        let metaData = try Data(contentsOf: bundle.metadataURL)
        let meta = try JSONDecoder().decode(RecordingMetadata.self, from: metaData)

        let firstPTS = meta.firstVideoPTS.cmTime
        let lastPTS = meta.lastVideoPTS.cmTime
        let timelineDuration = TimePoint(CMTimeSubtract(lastPTS, firstPTS))

        let sidecars: [SidecarRef] = [
            SidecarRef(streamID: "cursor", relativePath: "cursor.json", kind: .cursor),
        ]

        let screen = SourceClip(
            id: "screen",
            relativeMediaPath: "screen.mov",
            widthPx: meta.widthPx,
            heightPx: meta.heightPx,
            firstPTS: meta.firstVideoPTS,
            sidecars: sidecars
        )

        var sources: [SourceClip] = [screen]

        // Webcam, if present.
        let webcamURL = bundle.url.appendingPathComponent("webcam.mov")
        let hasWebcam = FileManager.default.fileExists(atPath: webcamURL.path)
        if hasWebcam {
            let webcam = SourceClip(
                id: "webcam",
                relativeMediaPath: "webcam.mov",
                widthPx: 1280, heightPx: 720,   // overwritten by reader at render time
                firstPTS: meta.firstVideoPTS,
                sidecars: []
            )
            sources.append(webcam)
        }

        // Output canvas: 16:9 at 1920×1080 by default. Source aspect doesn't have
        // to match — BackgroundCompose centers and pads.
        let canvas = CanvasSpec(widthPx: 1920, heightPx: 1080)

        // Standard envelopes.
        let bubbleEnv = Envelope(attack: 0.04, hold: 0.0, release: 0.5, ease: .easeOut)

        let cursorBinding = ParamBinding.streamBound(StreamBound(
            streamID: "cursor",
            component: .point2,
            smoothingSec: 0.05,
            defaultValue: .point2(x: -1000, y: -1000)
        ))

        let cursorPaint = NodeInstance(
            instanceID: "cursor_paint_1",
            nodeType: CursorPaint.spec.id,
            bindings: [
                "position": cursorBinding,
                "scale": .constant(.scalar(2.4)),
                "visible": .constant(.bool(true)),
                "highlightAlpha": .constant(.scalar(0.45)),
                "highlightRadius": .constant(.scalar(36)),
            ]
        )
        let clickBubble = NodeInstance(
            instanceID: "click_bubble_1",
            nodeType: ClickBubble.spec.id,
            bindings: [
                "intensity": .eventDriven(EventDriven(
                    streamID: "clicks", envelope: bubbleEnv,
                    rest: .scalar(0), peak: .scalar(1)
                )),
                "position": cursorBinding,
                "maxRadiusPx": .constant(.scalar(180)),
            ]
        )
        // Zoom node's scale binding is overridden by zoomRegions in the renderer.
        // Default to 1.0 (no zoom) so removing all regions returns to unzoomed.
        let zoom = NodeInstance(
            instanceID: "zoom_1",
            nodeType: Zoom.spec.id,
            bindings: [
                "scale": .constant(.scalar(1.0)),
                "center": cursorBinding,
            ]
        )
        let bg = NodeInstance(
            instanceID: "bg_1",
            nodeType: BackgroundCompose.spec.id,
            bindings: [:]
        )
        var nodes: [NodeInstance] = [cursorPaint, clickBubble, zoom, bg]
        if hasWebcam {
            let webcamNode = NodeInstance(
                instanceID: "webcam_1",
                nodeType: WebcamOverlay.spec.id,
                bindings: [
                    "sizePx": .constant(.scalar(220)),
                    "marginPx": .constant(.scalar(48)),
                    "corner": .constant(.scalar(3)),
                    "visible": .constant(.bool(true)),
                ]
            )
            nodes.append(webcamNode)
        }

        // Caption overlay node — disabled until user generates captions.
        let captionNode = NodeInstance(
            instanceID: "captions_1",
            nodeType: CaptionOverlay.spec.id,
            bindings: [
                "visible": .constant(.bool(true)),
                "fontSize": .constant(.scalar(56)),
                "marginPx": .constant(.scalar(120)),
            ],
            enabled: false
        )
        nodes.append(captionNode)

        let videoTrack = VideoTrack(segments: [
            VideoSegment(
                sourceID: "screen",
                sourceIn: meta.firstVideoPTS,
                sourceOut: meta.lastVideoPTS,
                timelineIn: TimePoint(.zero)
            )
        ])

        let zoomRegions = autoZoomRegionsFromClicks(bundle: bundle, meta: meta)

        return Project(
            sources: sources,
            videoTrack: videoTrack,
            nodeGraph: NodeGraph(nodes: nodes),
            canvas: canvas,
            timelineDuration: timelineDuration,
            zoomRegions: zoomRegions
        )
    }

    private static func autoZoomRegionsFromClicks(
        bundle: ProjectBundle, meta: RecordingMetadata
    ) -> [ZoomRegion] {
        // Best-effort: read cursor.json clicks; build merged time ranges around each.
        struct RawSidecar: Codable {
            var clicks: [Click]
            struct Click: Codable {
                var t: TimePoint; var phase: String
            }
        }
        guard let data = try? Data(contentsOf: bundle.cursorURL),
              let raw = try? JSONDecoder().decode(RawSidecar.self, from: data) else {
            return []
        }
        let originS = meta.firstVideoPTS.cmTime.seconds
        let downs = raw.clicks
            .filter { $0.phase == "down" }
            .map { $0.t.cmTime.seconds - originS }
            .filter { $0 >= 0 }
        guard !downs.isEmpty else { return [] }

        // Each click → a 1.5s region centered slightly after the click.
        var regions: [(Double, Double)] = []
        let preLead: Double = 0.2
        let postHold: Double = 1.5
        for t in downs {
            let inS = max(0, t - preLead)
            let outS = t + postHold
            // Merge if overlapping with last.
            if var last = regions.last, inS <= last.1 + 0.05 {
                last.1 = max(last.1, outS)
                regions[regions.count - 1] = last
            } else {
                regions.append((inS, outS))
            }
        }
        return regions.enumerated().map { (i, span) in
            ZoomRegion(
                id: "auto_\(i)",
                timelineIn: TimePoint(CMTime(seconds: span.0, preferredTimescale: 600)),
                timelineOut: TimePoint(CMTime(seconds: span.1, preferredTimescale: 600)),
                scale: 1.45,
                followCursor: true,
                fixedCenter: nil,
                transitionSec: 0.45,
                auto: true
            )
        }
    }
}
