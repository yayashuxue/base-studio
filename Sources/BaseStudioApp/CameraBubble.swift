import AppKit
import AVFoundation

/// Floating, draggable, mirrored self-view while recording. Shows the
/// recorder's own camera session (no second camera open). Base Studio's
/// windows are left out of display capture, so the bubble is never
/// recorded — the webcam reaches the video from its own track.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private static let size: CGFloat = 160

    func show(session: AVCaptureSession) {
        hide()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let s = Self.size
        let panel = NSPanel(
            contentRect: NSRect(x: visible.maxX - s - 24, y: visible.minY + 24, width: s, height: s),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        host.wantsLayer = true
        host.layer?.cornerRadius = s / 2
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 2
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = host.bounds
        preview.videoGravity = .resizeAspectFill
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        host.layer?.addSublayer(preview)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
