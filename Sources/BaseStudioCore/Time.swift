import CoreMedia
import Foundation

/// Single-source clock for the entire app. Video PTSes from ScreenCaptureKit are
/// produced against `CMClockGetHostTimeClock()`; cursor samples and click events
/// must sample from the same clock so that downstream sync is exact, not approximate.
public enum HostClock {
    public static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}

/// Codable wrapper for CMTime. We persist time as a rational `{value, timescale}`
/// pair (per PRD §1 invariant 3 — never as float seconds).
public struct TimePoint: Codable, Hashable, Sendable {
    public let value: Int64
    public let timescale: Int32

    public init(_ t: CMTime) {
        self.value = t.value
        self.timescale = t.timescale
    }

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }

    public var seconds: Double {
        cmTime.seconds
    }
}
