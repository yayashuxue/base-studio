import CoreMedia
import Foundation

/// A time-ranged zoom segment on the timeline. The user-facing "zoom slice" —
/// the purple bars on the timeline. Multiple may exist; renderer picks the one
/// active at time `t` (by max envelope when overlapping).
public struct ZoomRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var timelineIn: TimePoint     // source-time relative to trim_in
    public var timelineOut: TimePoint    // source-time relative to trim_in
    public var scale: Double             // peak zoom (1.0 = no zoom)
    public var followCursor: Bool        // true → center = cursor at t; false → fixed
    public var fixedCenter: Point2D?     // used when followCursor == false
    public var transitionSec: Double     // attack/release ramp seconds
    public var auto: Bool                // true = generated from a click (can be regenerated)
    public var speed: Double             // playback speed during this region (1.0 = passthrough)

    public init(
        id: String,
        timelineIn: TimePoint, timelineOut: TimePoint,
        scale: Double = 1.45,
        followCursor: Bool = true,
        fixedCenter: Point2D? = nil,
        transitionSec: Double = 0.45,
        auto: Bool = false,
        speed: Double = 1.0
    ) {
        self.id = id
        self.timelineIn = timelineIn
        self.timelineOut = timelineOut
        self.scale = scale
        self.followCursor = followCursor
        self.fixedCenter = fixedCenter
        self.transitionSec = transitionSec
        self.auto = auto
        self.speed = speed
    }

    private enum CodingKeys: String, CodingKey {
        case id, timelineIn, timelineOut, scale, followCursor, fixedCenter
        case transitionSec, auto, speed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timelineIn = try c.decode(TimePoint.self, forKey: .timelineIn)
        timelineOut = try c.decode(TimePoint.self, forKey: .timelineOut)
        scale = try c.decode(Double.self, forKey: .scale)
        followCursor = try c.decode(Bool.self, forKey: .followCursor)
        fixedCenter = try c.decodeIfPresent(Point2D.self, forKey: .fixedCenter)
        transitionSec = try c.decode(Double.self, forKey: .transitionSec)
        auto = try c.decode(Bool.self, forKey: .auto)
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.0
    }
}

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Evaluation helpers — compute the active zoom params at timeline time `t`.
public enum ZoomRegionResolver {

    /// Returns (scale, followCursor, fixedCenter?) at time `t`, or nil if no region active.
    public static func resolved(
        at t: CMTime, regions: [ZoomRegion]
    ) -> (scale: Double, followCursor: Bool, fixedCenter: Point2D?)? {
        let ts = t.seconds
        var best: (Double, ZoomRegion)? = nil
        for r in regions {
            let inS = r.timelineIn.seconds
            let outS = r.timelineOut.seconds
            guard outS > inS else { continue }
            let trans = max(0, min(r.transitionSec, (outS - inS) / 2))

            let e: Double
            if ts < inS - 0.001 || ts > outS + 0.001 { e = 0 }
            else if ts < inS + trans { e = ease((ts - inS) / max(trans, 1e-6)) }
            else if ts > outS - trans { e = 1 - ease((ts - (outS - trans)) / max(trans, 1e-6)) }
            else { e = 1.0 }

            if e > 0 {
                let s = 1.0 + e * (r.scale - 1.0)
                if best == nil || s > best!.0 {
                    best = (s, r)
                }
            }
        }
        guard let (scale, region) = best else { return nil }
        return (scale, region.followCursor, region.fixedCenter)
    }

    /// Smooth ease — 3t² - 2t³.
    @inline(__always)
    private static func ease(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}
