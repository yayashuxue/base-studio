import AppKit
import AVFoundation
import XCTest
@testable import BaseStudioApp

/// Real on-screen renders (vibrancy and window shadows need the window
/// server) of the recording control bar and camera bubble, including the
/// shadow, over a white backdrop — so stray square frames around rounded
/// windows are visible. Written to /tmp/control-bar.png, /tmp/camera-bubble.png.
final class ControlBarSnapshotTests: XCTestCase {

    @MainActor
    func testRenderControlBarAndBubble() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let bar = RecordingPanel()
        bar.show()
        let bubble = CameraBubble()
        bubble.show(session: AVCaptureSession())
        defer { bar.hide(); bubble.hide() }
        try await Task.sleep(nanoseconds: 800_000_000)
        try snapshot(XCTUnwrap(bar.panel), to: "/tmp/control-bar.png")
        try snapshot(XCTUnwrap(bubble.panel), to: "/tmp/camera-bubble.png")
    }

    /// Window + its shadow, composited over white.
    @MainActor
    private func snapshot(_ w: NSWindow, to path: String) throws {
        let cg = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution]))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: cg.width, height: cg.height).fill()
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
