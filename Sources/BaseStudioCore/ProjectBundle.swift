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
    /// Best-effort forensic sidecar written when `RecordingSession.stop()`
    /// could not produce a valid bundle (e.g. the HW encoder erroring on the
    /// first frame, finishWriting throwing). Presence = "this bundle is
    /// known broken, here's what went wrong". Readers should treat it as
    /// purely diagnostic.
    public var failureURL: URL { url.appendingPathComponent("failure.json") }

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

/// Per-source media anchor — captured at record time so playback/export can
/// convert between host-clock PTSes (the shared timebase across recorders) and
/// the on-disk file-time of each source. Without this, non-primary sources
/// (webcam, future face-cam, screen-secondary) cannot be sampled correctly:
/// `AVAssetWriter.startSession(atSourceTime:)` shifts the on-disk track to
/// start at file-time 0, so feeding host-clock PTSes to `AVAssetImageGenerator`
/// returns the last frame on every seek.
public struct SourceMediaInfo: Codable, Sendable {
    public let firstVideoPTS: TimePoint   // host-clock PTS of this source's first frame
    public let lastVideoPTS: TimePoint    // host-clock PTS of this source's last frame
    public let widthPx: Int
    public let heightPx: Int

    public init(
        firstVideoPTS: TimePoint,
        lastVideoPTS: TimePoint,
        widthPx: Int,
        heightPx: Int
    ) {
        self.firstVideoPTS = firstVideoPTS
        self.lastVideoPTS = lastVideoPTS
        self.widthPx = widthPx
        self.heightPx = heightPx
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
    public let firstVideoPTS: TimePoint      // anchor: screen first frame's PTS on host clock
    public let lastVideoPTS: TimePoint       // anchor: screen last frame's PTS on host clock
    /// Per-source anchors keyed by source id ("screen", "webcam", …).
    /// Optional for back-compat with bundles recorded before this field existed.
    /// Always populated for new recordings; readers should fall back to the
    /// top-level firstVideoPTS / lastVideoPTS when absent.
    public let sources: [String: SourceMediaInfo]?
    /// Host-clock PTS of mic.m4a's first sample. Optional for back-compat AND
    /// for recordings made without `includeMic`. Mic gets its own field rather
    /// than living in `sources` because `SourceMediaInfo` carries video-only
    /// fields (widthPx/heightPx) — keeping audio cleanly typed.
    public let micFirstPTS: TimePoint?

    public init(
        displayID: UInt32,
        widthPx: Int, heightPx: Int,
        pointScale: Double,
        displayOriginXPt: Double, displayOriginYPt: Double,
        displayWidthPt: Double, displayHeightPt: Double,
        firstVideoPTS: TimePoint,
        lastVideoPTS: TimePoint,
        sources: [String: SourceMediaInfo]? = nil,
        micFirstPTS: TimePoint? = nil
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
        self.sources = sources
        self.micFirstPTS = micFirstPTS
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, widthPx, heightPx, pointScale
        case displayOriginXPt, displayOriginYPt, displayWidthPt, displayHeightPt
        case firstVideoPTS, lastVideoPTS, sources, micFirstPTS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try c.decode(UInt32.self, forKey: .displayID)
        widthPx = try c.decode(Int.self, forKey: .widthPx)
        heightPx = try c.decode(Int.self, forKey: .heightPx)
        pointScale = try c.decode(Double.self, forKey: .pointScale)
        displayOriginXPt = try c.decode(Double.self, forKey: .displayOriginXPt)
        displayOriginYPt = try c.decode(Double.self, forKey: .displayOriginYPt)
        displayWidthPt = try c.decode(Double.self, forKey: .displayWidthPt)
        displayHeightPt = try c.decode(Double.self, forKey: .displayHeightPt)
        firstVideoPTS = try c.decode(TimePoint.self, forKey: .firstVideoPTS)
        lastVideoPTS = try c.decode(TimePoint.self, forKey: .lastVideoPTS)
        sources = try? c.decode([String: SourceMediaInfo].self, forKey: .sources)
        micFirstPTS = try? c.decode(TimePoint.self, forKey: .micFirstPTS)
    }
}
