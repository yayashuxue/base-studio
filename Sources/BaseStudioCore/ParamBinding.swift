import Foundation

/// How a parameter's value is produced over time. The architectural payoff: one
/// `Zoom` node serves manual-zoom, follow-mouse-zoom, and auto-zoom-on-click — all
/// three are different `ParamBinding`s of the same params (TECH_DESIGN §3).
public enum ParamBinding: Codable, Sendable {
    /// Fixed value for all time.
    case constant(ParamValue)

    /// Piecewise interpolation over user-placed keyframes.
    case keyframed(Keyframed)

    /// Sampled from a sidecar stream at time `t` (e.g. cursor position).
    case streamBound(StreamBound)

    /// Driven by discrete events with a temporal envelope (e.g. auto-zoom on click).
    case eventDriven(EventDriven)
}

public struct Keyframed: Codable, Sendable {
    public var keyframes: [Keyframe]
    public var defaultValue: ParamValue

    public init(keyframes: [Keyframe], defaultValue: ParamValue) {
        self.keyframes = keyframes
        self.defaultValue = defaultValue
    }
}

public struct Keyframe: Codable, Sendable {
    public var t: TimePoint
    public var value: ParamValue
    public var ease: Ease

    public init(t: TimePoint, value: ParamValue, ease: Ease = .easeInOut) {
        self.t = t
        self.value = value
        self.ease = ease
    }
}

public struct StreamBound: Codable, Sendable {
    public var streamID: String          // e.g. "cursor"
    public var component: Component
    public var smoothingSec: Double      // damping window for jitter; 0 = none
    public var defaultValue: ParamValue

    public enum Component: String, Codable, Sendable {
        case point2
        case scalar  // when stream values are 1-D
    }

    public init(
        streamID: String,
        component: Component = .point2,
        smoothingSec: Double = 0,
        defaultValue: ParamValue
    ) {
        self.streamID = streamID
        self.component = component
        self.smoothingSec = smoothingSec
        self.defaultValue = defaultValue
    }
}

public struct EventDriven: Codable, Sendable {
    public var streamID: String          // e.g. "clicks"
    public var envelope: Envelope
    public var rest: ParamValue          // value when no event is active
    public var peak: ParamValue          // value at envelope peak

    public init(streamID: String, envelope: Envelope, rest: ParamValue, peak: ParamValue) {
        self.streamID = streamID
        self.envelope = envelope
        self.rest = rest
        self.peak = peak
    }
}

/// ADSR-ish envelope, in seconds, applied around each event time.
public struct Envelope: Codable, Sendable {
    public var attack: Double
    public var hold: Double
    public var release: Double
    public var ease: Ease

    public init(attack: Double, hold: Double, release: Double, ease: Ease = .easeInOut) {
        self.attack = attack
        self.hold = hold
        self.release = release
        self.ease = ease
    }

    /// Returns 0..1 envelope value at time-since-event `dt` seconds.
    public func value(at dt: Double) -> Double {
        if dt < 0 { return 0 }
        if dt < attack {
            return ease.apply(dt / max(attack, 1e-6))
        }
        if dt < attack + hold {
            return 1.0
        }
        let r = dt - attack - hold
        if r < release {
            return 1.0 - ease.apply(r / max(release, 1e-6))
        }
        return 0
    }

    public var totalDuration: Double { attack + hold + release }
}
