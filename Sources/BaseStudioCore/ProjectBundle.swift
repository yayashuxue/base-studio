import CoreMedia
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

    /// Always a NEW, empty bundle: if `<name>.basestudio` exists (two takes
    /// in the same second, a re-run self-test) the next free `<name>-2`,
    /// `<name>-3`, … is used. An existing recording is never reused or
    /// overwritten — a re-run once replaced the only copy of a 330 s take.
    public static func create(in directory: URL, name: String) throws -> ProjectBundle {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for n in 1...10_000 {
            let stem = n == 1 ? name : "\(name)-\(n)"
            let bundleURL = directory.appendingPathComponent("\(stem).basestudio", isDirectory: true)
            do {
                // Without intermediates, createDirectory fails if it exists —
                // check and claim in one step, no race with a second recorder.
                try fm.createDirectory(at: bundleURL, withIntermediateDirectories: false)
                return ProjectBundle(url: bundleURL)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
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

    /// Pixels of the recorded frame per display point — what cursor/click
    /// coordinates (points) must be multiplied by. Taken from the frame
    /// itself, not `pointScale`: takes recorded at 1× on a 2× Retina display
    /// (1512 px wide, 1512 pt) stored pointScale 2, which put the cursor
    /// at twice its position — off the frame, so it never showed.
    /// Host-clock intervals during which the take was paused: nothing was
    /// recorded there. Optional for older bundles.
    public var pauses: [PauseInterval]?

    public var pixelsPerPoint: Double {
        displayWidthPt > 0 ? Double(widthPx) / displayWidthPt : pointScale
    }

    public init(
        displayID: UInt32,
        widthPx: Int, heightPx: Int,
        pointScale: Double,
        displayOriginXPt: Double, displayOriginYPt: Double,
        displayWidthPt: Double, displayHeightPt: Double,
        firstVideoPTS: TimePoint,
        lastVideoPTS: TimePoint,
        sources: [String: SourceMediaInfo]? = nil,
        micFirstPTS: TimePoint? = nil,
        pauses: [PauseInterval]? = nil
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
        self.pauses = pauses
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, widthPx, heightPx, pointScale
        case displayOriginXPt, displayOriginYPt, displayWidthPt, displayHeightPt
        case firstVideoPTS, lastVideoPTS, sources, micFirstPTS, pauses
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
        pauses = try? c.decode([PauseInterval].self, forKey: .pauses)
    }

    /// Pauses as cuts in seconds from the screen's first frame.
    public var pauseCuts: [SourceCut] {
        let origin = firstVideoPTS.cmTime
        return (pauses ?? []).map {
            SourceCut(startSec: CMTimeSubtract($0.start.cmTime, origin).seconds,
                      endSec: CMTimeSubtract($0.end.cmTime, origin).seconds)
        }
    }
}

public struct PauseInterval: Codable, Sendable, Equatable {
    public var start: TimePoint
    public var end: TimePoint
    public init(start: TimePoint, end: TimePoint) { self.start = start; self.end = end }
}
