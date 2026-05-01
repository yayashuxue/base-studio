import AVFoundation
import AppKit
import SwiftUI

/// Live camera preview using AVCaptureVideoPreviewLayer. Used:
///   - in the toolbar BEFORE recording (so the user can frame themselves);
///   - in the floating recording panel DURING recording.
///
/// Owns its own AVCaptureSession (separate from `WebcamRecorder`) so preview can
/// run independently of writing.
@MainActor
final class WebcamPreviewSession: ObservableObject {
    @Published var isRunning = false
    @Published var permissionDenied = false

    let session = AVCaptureSession()
    private var configured = false

    func startIfPossible() async {
        guard !isRunning else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            permissionDenied = true
            return
        }
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { permissionDenied = true; return }
        }
        if !configured {
            configure()
            configured = true
        }
        await Task.detached { [session] in session.startRunning() }.value
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    private func configure() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()
    }
}

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer.
struct WebcamPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        v.applyMirror(mirrored)
        return v
    }
    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
        nsView.applyMirror(mirrored)
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
        func applyMirror(_ on: Bool) {
            if let conn = previewLayer.connection, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = on
            }
        }
    }
}
