import AppKit
import CoreMedia
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioCore

/// Preview must read every source (screen, webcam) and the cursor/zoom time
/// through the same TimeMap as export — across a cut and a trim.
final class EditorCutMappingTests: XCTestCase {

    @MainActor
    func testWebcamAndSourceTimeFollowTheCut() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let t0 = CMTime(seconds: 1000, preferredTimescale: 600)
        func at(_ s: Double) -> CMTime { CMTimeAdd(t0, CMTime(seconds: s, preferredTimescale: 600)) }
        let screen = SourceClip(id: SourceID.screen, relativeMediaPath: "screen.mov",
                                widthPx: 1512, heightPx: 982, firstPTS: TimePoint(t0), sidecars: [])
        // Webcam started 0.2 s before the screen.
        let webcam = SourceClip(id: SourceID.webcam, relativeMediaPath: "webcam.mov",
                                widthPx: 1280, heightPx: 720, firstPTS: TimePoint(at(-0.2)), sidecars: [])
        // Trimmed to start at 1 s; paused 3–6 s (source, from first frame).
        let project = Project(
            sources: [screen, webcam],
            videoTrack: VideoTrack(segments: [VideoSegment(
                sourceID: SourceID.screen, sourceIn: TimePoint(at(1)), sourceOut: TimePoint(at(10)),
                timelineIn: TimePoint(.zero))]),
            nodeGraph: NodeGraph(nodes: []), canvas: CanvasSpec(widthPx: 1920, heightPx: 1080),
            timelineDuration: TimePoint(CMTime(seconds: 9, preferredTimescale: 600)),
            cuts: [SourceCut(startSec: 3, endSec: 6)]
        )
        let meta = RecordingMetadata(
            displayID: 1, widthPx: 1512, heightPx: 982, pointScale: 1,
            displayOriginXPt: 0, displayOriginYPt: 0, displayWidthPt: 1512, displayHeightPt: 982,
            firstVideoPTS: TimePoint(t0), lastVideoPTS: TimePoint(at(10)))
        let editor = EditorState(project: project,
                                 bundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("m.basestudio"),
                                 sidecars: SidecarStreams(), primary: screen, recordingMeta: meta)

        XCTAssertEqual(editor.timelineDurationSec, 6, accuracy: 1e-6)   // 9 s − 3 s pause
        func secs(_ t: CMTime) -> Double { t.seconds }
        // Timeline 1.5 s → source 2.5 s (before the cut).
        let a = CMTime(seconds: 1.5, preferredTimescale: 600)
        XCTAssertEqual(secs(editor.seekTime(forSource: screen, timelinePTS: a)), 2.5, accuracy: 1e-3)
        XCTAssertEqual(secs(editor.seekTime(forSource: webcam, timelinePTS: a)), 2.7, accuracy: 1e-3)
        XCTAssertEqual(secs(editor.sourceTime(at: a)), 1.5, accuracy: 1e-3)      // since trim-in
        // Timeline 2.0 s is the join → where recording resumed (6 s).
        let b = CMTime(seconds: 2.0, preferredTimescale: 600)
        XCTAssertEqual(secs(editor.seekTime(forSource: screen, timelinePTS: b)), 6.0, accuracy: 1e-3)
        XCTAssertEqual(secs(editor.seekTime(forSource: webcam, timelinePTS: b)), 6.2, accuracy: 1e-3)
        XCTAssertEqual(secs(editor.sourceTime(at: b)), 5.0, accuracy: 1e-3)
    }
}
