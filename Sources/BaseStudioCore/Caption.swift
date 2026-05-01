import CoreMedia
import Foundation

public struct Caption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var startSec: Double      // timeline-relative
    public var endSec: Double
    public var text: String

    public init(id: String, startSec: Double, endSec: Double, text: String) {
        self.id = id
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
    }
}

public enum CaptionResolver {
    /// Active caption text at timeline time `t`, if any.
    public static func active(at t: CMTime, captions: [Caption]) -> String? {
        let ts = t.seconds
        for c in captions where ts >= c.startSec - 0.01 && ts <= c.endSec + 0.01 {
            return c.text
        }
        return nil
    }
}
