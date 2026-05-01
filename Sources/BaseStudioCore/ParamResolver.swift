import CoreMedia
import Foundation

/// Resolved parameter values for one node at one moment in time.
public struct ParamValues: Sendable {
    public var values: [String: ParamValue]
    public init(_ values: [String: ParamValue] = [:]) { self.values = values }
    public subscript(name: String) -> ParamValue? { values[name] }
}

/// Pure resolver: (binding, t, sidecars) → ParamValue. No side effects, no caching.
/// Caching, if added later, must be keyed by (EDL hash, t) per PRD §11.
public enum ParamResolver {

    public static func resolve(
        bindings: [String: ParamBinding],
        at t: CMTime,
        streamTime: CMTime? = nil,
        sidecars: SidecarStreams
    ) -> ParamValues {
        let st = streamTime ?? t
        var out: [String: ParamValue] = [:]
        for (name, binding) in bindings {
            out[name] = resolveOne(binding: binding, at: t, streamTime: st, sidecars: sidecars)
        }
        return ParamValues(out)
    }

    public static func resolveOne(
        binding: ParamBinding,
        at t: CMTime,
        streamTime: CMTime? = nil,
        sidecars: SidecarStreams
    ) -> ParamValue {
        let st = streamTime ?? t
        switch binding {
        case .constant(let v):
            return v
        case .keyframed(let kf):
            return resolveKeyframed(kf, at: t)
        case .streamBound(let sb):
            return resolveStreamBound(sb, at: st, sidecars: sidecars)
        case .eventDriven(let ed):
            return resolveEventDriven(ed, at: st, sidecars: sidecars)
        }
    }

    private static func resolveKeyframed(_ kf: Keyframed, at t: CMTime) -> ParamValue {
        let kfs = kf.keyframes
        if kfs.isEmpty { return kf.defaultValue }
        let ts = t.seconds
        if ts <= kfs[0].t.seconds { return kfs[0].value }
        if ts >= kfs.last!.t.seconds { return kfs.last!.value }
        // Find bracket.
        for i in 0..<(kfs.count - 1) {
            let a = kfs[i], b = kfs[i + 1]
            if ts >= a.t.seconds && ts <= b.t.seconds {
                let span = b.t.seconds - a.t.seconds
                let u = span > 0 ? (ts - a.t.seconds) / span : 0
                return ParamValue.lerp(a.value, b.value, b.ease.apply(u))
            }
        }
        return kf.defaultValue
    }

    private static func resolveStreamBound(
        _ sb: StreamBound, at t: CMTime, sidecars: SidecarStreams
    ) -> ParamValue {
        guard let samples = sidecars.cursorPositions[sb.streamID] else {
            return sb.defaultValue
        }
        // Optional smoothing: average over a window centered on t.
        if sb.smoothingSec > 0 {
            let window = sb.smoothingSec / 2
            let lo = CMTimeAdd(t, CMTimeMakeWithSeconds(-window, preferredTimescale: 600))
            let hi = CMTimeAdd(t, CMTimeMakeWithSeconds(+window, preferredTimescale: 600))
            let lo_s = lo.seconds, hi_s = hi.seconds
            var sx = 0.0, sy = 0.0, n = 0.0
            for s in samples where s.pts.seconds >= lo_s && s.pts.seconds <= hi_s {
                sx += s.x; sy += s.y; n += 1
            }
            if n > 0 {
                return .point2(x: sx / n, y: sy / n)
            }
        }
        if let (x, y) = CursorSampler.position(in: samples, at: t) {
            return .point2(x: x, y: y)
        }
        return sb.defaultValue
    }

    private static func resolveEventDriven(
        _ ed: EventDriven, at t: CMTime, sidecars: SidecarStreams
    ) -> ParamValue {
        guard let events = sidecars.clickEvents[ed.streamID] else { return ed.rest }
        let ts = t.seconds
        let env = ed.envelope
        // Take the max envelope value across overlapping events near t.
        var maxV = 0.0
        let lookback = env.attack + env.hold + env.release
        for ev in events where ev.phase == "down" {
            let dt = ts - ev.pts.seconds
            if dt < 0 { continue }
            if dt > lookback { continue }
            let v = env.value(at: dt)
            if v > maxV { maxV = v }
        }
        return ParamValue.lerp(ed.rest, ed.peak, maxV)
    }
}
