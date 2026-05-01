import CoreMedia
import Foundation

/// In-memory sidecar streams indexed by `streamID`. Loaded once per render session.
public struct SidecarStreams: Sendable {
    public var cursorPositions: [String: [CursorPosSample]]   // streamID → samples
    public var clickEvents: [String: [ClickEventSample]]      // streamID → events

    public init(
        cursorPositions: [String: [CursorPosSample]] = [:],
        clickEvents: [String: [ClickEventSample]] = [:]
    ) {
        self.cursorPositions = cursorPositions
        self.clickEvents = clickEvents
    }
}

public struct CursorPosSample: Codable, Sendable {
    public var pts: TimePoint
    public var x: Double
    public var y: Double
    public init(pts: TimePoint, x: Double, y: Double) {
        self.pts = pts; self.x = x; self.y = y
    }
}

public struct ClickEventSample: Codable, Sendable {
    public var pts: TimePoint
    public var x: Double
    public var y: Double
    public var phase: String     // "down" | "up"
    public var button: String    // "left" | "right"
    public init(pts: TimePoint, x: Double, y: Double, phase: String, button: String) {
        self.pts = pts; self.x = x; self.y = y; self.phase = phase; self.button = button
    }
}

/// Sample a cursor stream at time `t`. Catmull-Rom over the 4 surrounding samples
/// (PRD §7 — smooth cursor). Falls back to linear/clamp at the boundaries.
public enum CursorSampler {
    public static func position(in samples: [CursorPosSample], at t: CMTime) -> (Double, Double)? {
        guard !samples.isEmpty else { return nil }
        if samples.count == 1 { return (samples[0].x, samples[0].y) }

        let ts = t.seconds
        // Find first sample >= t.
        var hi = samples.count
        var lo = 0
        while lo < hi {
            let m = (lo + hi) / 2
            if samples[m].pts.seconds < ts { lo = m + 1 } else { hi = m }
        }
        if lo == 0 { return (samples[0].x, samples[0].y) }
        if lo >= samples.count { return (samples.last!.x, samples.last!.y) }

        let i1 = lo - 1
        let i2 = lo
        let i0 = max(0, i1 - 1)
        let i3 = min(samples.count - 1, i2 + 1)

        let p0 = samples[i0], p1 = samples[i1], p2 = samples[i2], p3 = samples[i3]
        let span = p2.pts.seconds - p1.pts.seconds
        let u = span > 0 ? (ts - p1.pts.seconds) / span : 0

        return (
            catmullRom(p0.x, p1.x, p2.x, p3.x, u),
            catmullRom(p0.y, p1.y, p2.y, p3.y, u)
        )
    }

    @inline(__always)
    private static func catmullRom(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (
            (2 * b)
            + (-a + c) * t
            + (2 * a - 5 * b + 4 * c - d) * t2
            + (-a + 3 * b - 3 * c + d) * t3
        )
    }
}
