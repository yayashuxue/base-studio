import AppKit
import SwiftUI
import XCTest
@testable import BaseStudioApp

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
}
