import BaseStudioCore
import CoreMedia
import Foundation

/// Shared by every recorder of a take. While paused, samples are dropped —
/// nothing is written to disk — so a pause records nothing (not "record and
/// cut later"). Decided per sample by its host-clock PTS, so all tracks cut
/// at the same instant. The intervals go into metadata.json and become
/// `Project.cuts`, which close the gaps up on the timeline.
public final class PauseState: @unchecked Sendable {
    private let lock = NSLock()
    private var openSince: CMTime?
    private var closed: [(start: CMTime, end: CMTime)] = []

    public init() {}

    public var isPaused: Bool { lock.withLock { openSince != nil } }

    public func pause(at t: CMTime = HostClock.now()) {
        lock.withLock { if openSince == nil { openSince = t } }
    }

    public func resume(at t: CMTime = HostClock.now()) {
        lock.withLock {
            if let s = openSince { closed.append((s, max(s, t))); openSince = nil }
        }
    }

    /// Whether a sample at host time `pts` falls inside a pause.
    public func covers(_ pts: CMTime) -> Bool {
        lock.withLock {
            if let s = openSince, CMTimeCompare(pts, s) >= 0 { return true }
            return closed.contains { CMTimeCompare(pts, $0.start) >= 0 && CMTimeCompare(pts, $0.end) < 0 }
        }
    }

    /// Whether a sample lasting [pts, pts + duration) touches a pause. Audio
    /// buffers have length: one starting just before the pause and running
    /// into it still carries paused sound, so it is dropped whole.
    public func overlaps(_ pts: CMTime, duration: CMTime) -> Bool {
        let d = duration.isValid && duration.seconds > 0 ? duration : .zero
        let end = CMTimeAdd(pts, d)
        return lock.withLock {
            if let s = openSince, CMTimeCompare(end, s) > 0 || CMTimeCompare(pts, s) >= 0 { return true }
            return closed.contains { CMTimeCompare(pts, $0.end) < 0 && (CMTimeCompare(end, $0.start) > 0 || CMTimeCompare(pts, $0.start) >= 0) }
        }
    }

    /// Start of the pause in progress, if any.
    public var openPauseStart: CMTime? { lock.withLock { openSince } }

    /// Close an open pause at `t` and return all intervals.
    public func finish(at t: CMTime = HostClock.now()) -> [(start: CMTime, end: CMTime)] {
        resume(at: t)
        return lock.withLock { closed }
    }
}
