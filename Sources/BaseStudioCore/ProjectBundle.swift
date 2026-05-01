import Foundation

/// On-disk layout of a recording. The PRD calls for a `.basestudio` directory bundle
/// containing source media + sidecar streams + (eventually) the EDL.
///
/// M0 layout:
///   <name>.basestudio/
///     screen.mov         — raw H.264 capture (no cursor burned in)
///     cursor.json        — cursor positions + click events on host clock
///     metadata.json      — display info, timing anchors
public struct ProjectBundle {
    public let url: URL

    public var screenURL: URL { url.appendingPathComponent("screen.mov") }
    public var cursorURL: URL { url.appendingPathComponent("cursor.json") }
    public var metadataURL: URL { url.appendingPathComponent("metadata.json") }

    public init(url: URL) {
        self.url = url
    }

    public static func create(in directory: URL, name: String) throws -> ProjectBundle {
        let bundleURL = directory
            .appendingPathComponent("\(name).basestudio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL, withIntermediateDirectories: true
        )
        return ProjectBundle(url: bundleURL)
    }
}

public struct RecordingMetadata: Codable {
    public let displayID: UInt32
    public let widthPx: Int
    public let heightPx: Int
    public let pointScale: Double            // logical→pixel scale (e.g. 2.0 retina)
    public let displayOriginXPt: Double      // NSEvent global coords, bottom-left
    public let displayOriginYPt: Double
    public let displayWidthPt: Double
    public let displayHeightPt: Double
    public let firstVideoPTS: TimePoint      // anchor: first frame's PTS on host clock
    public let lastVideoPTS: TimePoint       // anchor: last frame's PTS on host clock

    public init(
        displayID: UInt32,
        widthPx: Int, heightPx: Int,
        pointScale: Double,
        displayOriginXPt: Double, displayOriginYPt: Double,
        displayWidthPt: Double, displayHeightPt: Double,
        firstVideoPTS: TimePoint,
        lastVideoPTS: TimePoint
    ) {
        self.displayID = displayID
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.pointScale = pointScale
        self.displayOriginXPt = displayOriginXPt
        self.displayOriginYPt = displayOriginYPt
        self.displayWidthPt = displayWidthPt
        self.displayHeightPt = displayHeightPt
        self.firstVideoPTS = firstVideoPTS
        self.lastVideoPTS = lastVideoPTS
    }
}
