import Foundation

/// Concrete value carried by a parameter at a moment in time.
public enum ParamValue: Codable, Equatable, Sendable {
    case scalar(Double)
    case point2(x: Double, y: Double)
    case color(r: Double, g: Double, b: Double, a: Double)
    case bool(Bool)

    public var asScalar: Double? {
        if case .scalar(let v) = self { return v } else { return nil }
    }
    public var asPoint2: (Double, Double)? {
        if case .point2(let x, let y) = self { return (x, y) } else { return nil }
    }
    public var asColor: (Double, Double, Double, Double)? {
        if case .color(let r, let g, let b, let a) = self { return (r, g, b, a) } else { return nil }
    }
    public var asBool: Bool? {
        if case .bool(let v) = self { return v } else { return nil }
    }

    /// Linear interpolation. For `bool`, picks `b` once `t >= 0.5`.
    public static func lerp(_ a: ParamValue, _ b: ParamValue, _ t: Double) -> ParamValue {
        switch (a, b) {
        case (.scalar(let x), .scalar(let y)):
            return .scalar(x + (y - x) * t)
        case (.point2(let x1, let y1), .point2(let x2, let y2)):
            return .point2(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
        case (.color(let r1, let g1, let b1, let a1), .color(let r2, let g2, let b2, let a2)):
            return .color(
                r: r1 + (r2 - r1) * t,
                g: g1 + (g2 - g1) * t,
                b: b1 + (b2 - b1) * t,
                a: a1 + (a2 - a1) * t
            )
        case (.bool, .bool):
            return t < 0.5 ? a : b
        default:
            return a
        }
    }
}

public enum Ease: String, Codable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    public func apply(_ t: Double) -> Double {
        let x = max(0.0, min(1.0, t))
        switch self {
        case .linear: return x
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .easeInOut:
            return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
    }
}
