import AppKit
import CoreMedia
import SwiftUI
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioCore

/// Offscreen before/after of the app chrome (Home screen) so the light-theme
/// pass can be verified headlessly (no Accessibility, no real recording). Set
/// CHROME_SNAP_LABEL to tag the output file: /tmp/chrome-home-<label>.png.
final class ChromeSnapshotTests: XCTestCase {

    @MainActor
    func testRenderHomeChrome() throws {
        // HomeView -> RecordingViewModel -> MenuBarController creates an
        // NSStatusItem, which needs a live WindowServer/CGS connection. Booting
        // the shared NSApplication as an accessory establishes it so the render
        // doesn't SIGABRT on CGSConnectionByID.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let label = ProcessInfo.processInfo.environment["CHROME_SNAP_LABEL"] ?? "current"
        let vm = RecordingViewModel()
        let webcam = WebcamPreviewSession()
        let screen = ScreenPreviewSession()

        let view = HomeView(vm: vm, webcamPreview: webcam, screenPreview: screen)
            .frame(width: 1280, height: 800)
            .background(BS.Color.bgGradient)
            .preferredColorScheme(.light)   // matches ContentView after the light-theme pass

        let data = try SnapshotProbeTests.renderPNG(view, size: CGSize(width: 1280, height: 800))
        let url = URL(fileURLWithPath: "/tmp/chrome-home-\(label).png")
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 5000, "home chrome snapshot suspiciously small")
    }

    @MainActor
    func testRenderEditorInspectorChrome() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let label = ProcessInfo.processInfo.environment["CHROME_SNAP_LABEL"] ?? "current"

        let screen = SourceClip(
            id: SourceID.screen, relativeMediaPath: "screen.mov",
            widthPx: 1512, heightPx: 982, firstPTS: TimePoint(.zero), sidecars: []
        )
        let bg = NodeInstance(instanceID: "bg_1", nodeType: "background_compose", bindings: [:])
        let project = Project(
            sources: [screen],
            videoTrack: VideoTrack(segments: [VideoSegment(
                sourceID: SourceID.screen, sourceIn: TimePoint(.zero),
                sourceOut: TimePoint(CMTime(seconds: 5, preferredTimescale: 600)),
                timelineIn: TimePoint(.zero)
            )]),
            nodeGraph: NodeGraph(nodes: [bg]),
            canvas: CanvasSpec(widthPx: 1920, heightPx: 1080),
            timelineDuration: TimePoint(CMTime(seconds: 5, preferredTimescale: 600))
        )
        let meta = RecordingMetadata(
            displayID: 1, widthPx: 1512, heightPx: 982, pointScale: 2,
            displayOriginXPt: 0, displayOriginYPt: 0,
            displayWidthPt: 1512, displayHeightPt: 982,
            firstVideoPTS: TimePoint(.zero),
            lastVideoPTS: TimePoint(CMTime(seconds: 5, preferredTimescale: 600)),
            sources: nil, micFirstPTS: nil
        )
        let editor = EditorState(
            project: project,
            bundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("mock.basestudio"),
            sidecars: SidecarStreams(),
            primary: screen,
            recordingMeta: meta
        )
        let vm = RecordingViewModel()

        let view = InspectorView(state: editor, vm: vm)
            .frame(width: 300, height: 820)
            .background(BS.Color.surface)
            .preferredColorScheme(.light)

        let data = try SnapshotProbeTests.renderPNG(view, size: CGSize(width: 300, height: 820))
        try data.write(to: URL(fileURLWithPath: "/tmp/chrome-inspector-\(label).png"))
        XCTAssertGreaterThan(data.count, 3000, "inspector snapshot suspiciously small")
    }
}
