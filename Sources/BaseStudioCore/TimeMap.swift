import CoreMedia
import Foundation

/// Bidirectional mapping between **timeline time** (what the viewer sees) and
/// **source-relative time** (offset into the recorded source clip after trim).
///
/// Built from a project's trim segment + `zoomRegions` (their `speed` field
/// drives time remapping). PRD §3 invariant: time mapping is *one piecewise
/// function* used by both video frame fetch and audio resampling — they cannot
/// drift because they read the same `f(t)`.
public struct TimeMap: Sendable {

    /// One linear-rate segment.
    public struct Segment: Sendable {
        public let sourceStart: Double      // source-relative seconds (0 = trim in)
        public let sourceEnd: Double        // source-relative seconds (exclusive)
        public let speed: Double            // > 0; 1.0 = passthrough
        public init(sourceStart: Double, sourceEnd: Double, speed: Double) {
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.speed = max(0.01, speed)
        }
        public var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
        public var timelineDuration: Double { sourceDuration / speed }
    }

    public let segments: [Segment]
    public let trimInSec: Double           // source-time of timeline 0 (host PTS - firstPTS)
    public let timelineDurationSec: Double

    public init(segments: [Segment], trimInSec: Double) {
        self.segments = segments
        self.trimInSec = trimInSec
        self.timelineDurationSec = segments.reduce(0) { $0 + $1.timelineDuration }
    }

    /// Identity mapping for a given trim window.
    public static func identity(trimInSec: Double, trimOutSec: Double) -> TimeMap {
        TimeMap(segments: [
            Segment(sourceStart: 0, sourceEnd: max(0, trimOutSec - trimInSec), speed: 1.0)
        ], trimInSec: trimInSec)
    }

    /// Build a TimeMap from project trim + speed-bearing zoom regions. Regions are
    /// in source-relative time; their speed splits the source range into segments.
    public static func make(
        trimInSec: Double, trimOutSec: Double,
        speedRegions: [(startSec: Double, endSec: Double, speed: Double)]
    ) -> TimeMap {
        let totalSourceDur = max(0, trimOutSec - trimInSec)
        // Sort + clamp + filter by speed != 1.0.
        let active = speedRegions
            .map { (max(0, $0.startSec), min(totalSourceDur, $0.endSec), max(0.01, $0.speed)) }
            .filter { $0.0 < $0.1 && abs($0.2 - 1.0) > 0.001 }
            .sorted { $0.0 < $1.0 }

        // Merge / drop overlaps: the FIRST one wins where overlap occurs.
        var resolved: [(Double, Double, Double)] = []
        var cursor: Double = 0
        for r in active {
            let start = max(r.0, cursor)
            let end = max(start, r.1)
            if start < end {
                resolved.append((start, end, r.2))
                cursor = end
            }
        }

        // Walk the source range, emit segments alternating between speed=1 and
        // a region's speed.
        var segments: [Segment] = []
        var pos: Double = 0
        for (s, e, sp) in resolved {
            if pos < s {
                segments.append(.init(sourceStart: pos, sourceEnd: s, speed: 1.0))
            }
            segments.append(.init(sourceStart: s, sourceEnd: e, speed: sp))
            pos = e
        }
        if pos < totalSourceDur {
            segments.append(.init(sourceStart: pos, sourceEnd: totalSourceDur, speed: 1.0))
        }
        if segments.isEmpty {
            segments.append(.init(sourceStart: 0, sourceEnd: totalSourceDur, speed: 1.0))
        }
        return TimeMap(segments: segments, trimInSec: trimInSec)
    }

    /// Source-relative seconds (0 = trim in) at a given timeline second.
    /// Returns clamped value if `t` is outside the timeline range.
    public func sourceSec(at timelineSec: Double) -> Double {
        var elapsed: Double = 0
        let target = max(0, min(timelineDurationSec, timelineSec))
        for seg in segments {
            let next = elapsed + seg.timelineDuration
            if target <= next + 1e-9 {
                let dt = target - elapsed
                return seg.sourceStart + dt * seg.speed
            }
            elapsed = next
        }
        return segments.last?.sourceEnd ?? 0
    }

    /// Source PTS (host-clock anchored, given the first-frame PTS) at timeline t.
    public func sourcePTS(at timelineSec: Double, firstPTS: CMTime) -> CMTime {
        let s = trimInSec + sourceSec(at: timelineSec)
        return CMTimeAdd(firstPTS, CMTime(seconds: s, preferredTimescale: 600))
    }

    /// Per-segment timeline → source ranges, useful for batch audio resampling.
    public struct TimelineSegment: Sendable {
        public let timelineStart: Double
        public let timelineEnd: Double
        public let sourceStart: Double
        public let sourceEnd: Double
        public let speed: Double
    }

    public func timelineSegments() -> [TimelineSegment] {
        var out: [TimelineSegment] = []
        var elapsed: Double = 0
        for seg in segments {
            let tlEnd = elapsed + seg.timelineDuration
            out.append(.init(
                timelineStart: elapsed, timelineEnd: tlEnd,
                sourceStart: seg.sourceStart, sourceEnd: seg.sourceEnd,
                speed: seg.speed
            ))
            elapsed = tlEnd
        }
        return out
    }
}
