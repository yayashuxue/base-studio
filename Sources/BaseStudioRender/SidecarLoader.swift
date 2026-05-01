import BaseStudioCore
import CoreMedia
import Foundation

/// Loads `cursor.json` (CursorRecorder.Sidecar shape) and converts to engine-side
/// `SidecarStreams`:
///   - PTSes are normalized from host-clock to timeline-relative (subtracting
///     `firstVideoPTS`).
///   - Cursor positions are transformed from global NSEvent point coords (bottom-left)
///     to source-pixel coords matching the captured video frame's CIImage extent
///     (also bottom-left, in pixels).
public enum SidecarLoader {
    public static func loadCursorJSON(
        at url: URL,
        meta: RecordingMetadata
    ) throws -> (cursor: [CursorPosSample], clicks: [ClickEventSample]) {
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode(RawCursorSidecar.self, from: data)
        let originPTS = meta.firstVideoPTS.cmTime

        let transform: (Double, Double) -> (Double, Double) = { gx, gy in
            // Global points → display-relative points.
            let lx = gx - meta.displayOriginXPt
            let ly = gy - meta.displayOriginYPt
            // → display pixels (bottom-left, matches CIImage origin convention).
            return (lx * meta.pointScale, ly * meta.pointScale)
        }

        let cursor = raw.samples.map { s -> CursorPosSample in
            let (px, py) = transform(s.x, s.y)
            let normalized = CMTimeSubtract(s.t.cmTime, originPTS)
            return CursorPosSample(pts: TimePoint(normalized), x: px, y: py)
        }
        let clicks = raw.clicks.map { c -> ClickEventSample in
            let (px, py) = transform(c.x, c.y)
            let normalized = CMTimeSubtract(c.t.cmTime, originPTS)
            return ClickEventSample(
                pts: TimePoint(normalized), x: px, y: py,
                phase: c.phase, button: c.button
            )
        }
        return (cursor, clicks)
    }

    private struct RawCursorSidecar: Codable {
        var samples: [Sample]
        var clicks: [Click]
        struct Sample: Codable { var t: TimePoint; var x: Double; var y: Double }
        struct Click: Codable {
            var t: TimePoint; var x: Double; var y: Double
            var phase: String; var button: String
        }
    }
}
