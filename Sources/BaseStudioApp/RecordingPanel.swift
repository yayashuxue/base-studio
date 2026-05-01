import AVFoundation
import AppKit
import BaseStudioRecording
import Foundation

/// Always-visible floating Stop panel. Sits above all windows at the top-center
/// of the main screen. Cannot be missed — large red Stop button, pulsing dot,
/// elapsed timer. Optionally embeds a small webcam preview circle next to the timer.
@MainActor
final class RecordingPanel {
    private var panel: NSPanel?
    private var elapsedLabel: NSTextField?
    private var dotLayer: CAShapeLayer?
    private var timer: Timer?
    private var startedAt: Date?
    private var webcamHostView: NSView?
    private var webcamPreviewLayer: AVCaptureVideoPreviewLayer?
    private weak var audioLevels: AudioLevels?
    private var micMeterLayer: CALayer?
    private var sysMeterLayer: CALayer?

    var onStop: (() -> Void)?

    func show(webcamSession: AVCaptureSession? = nil, levels: AudioLevels? = nil) {
        self.audioLevels = levels
        guard panel == nil else { return }
        let hasWebcam = webcamSession != nil

        let height: CGFloat = 64
        let width: CGFloat = hasWebcam ? 360 : 280
        let size = NSSize(width: width, height: height)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Top-center of the main screen, just below the menu bar so it isn't
        // obscured by the notch.
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.maxY - size.height - 40
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.45).cgColor

        // Pulsing red dot + REC label
        let dotContainer = NSView(frame: NSRect(x: 16, y: 22, width: 20, height: 20))
        dotContainer.wantsLayer = true
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 16, height: 16), transform: nil)
        dot.fillColor = NSColor.systemRed.cgColor
        dotContainer.layer?.addSublayer(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
        bg.addSubview(dotContainer)
        self.dotLayer = dot

        let label = NSTextField(labelWithString: "REC  0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.frame = NSRect(x: 42, y: 20, width: 120, height: 22)
        bg.addSubview(label)
        self.elapsedLabel = label

        // Two-row mic + system audio level meters under the timer (when levels available).
        if levels != nil {
            let metersHost = NSView(frame: NSRect(x: 42, y: 8, width: 120, height: 12))
            metersHost.wantsLayer = true
            bg.addSubview(metersHost)

            let micBg = CALayer()
            micBg.frame = CGRect(x: 0, y: 7, width: 120, height: 4)
            micBg.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            micBg.cornerRadius = 2
            metersHost.layer?.addSublayer(micBg)
            let micFill = CALayer()
            micFill.frame = CGRect(x: 0, y: 7, width: 0, height: 4)
            micFill.backgroundColor = NSColor.systemGreen.cgColor
            micFill.cornerRadius = 2
            metersHost.layer?.addSublayer(micFill)
            self.micMeterLayer = micFill

            let sysBg = CALayer()
            sysBg.frame = CGRect(x: 0, y: 1, width: 120, height: 4)
            sysBg.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            sysBg.cornerRadius = 2
            metersHost.layer?.addSublayer(sysBg)
            let sysFill = CALayer()
            sysFill.frame = CGRect(x: 0, y: 1, width: 0, height: 4)
            sysFill.backgroundColor = NSColor.systemBlue.cgColor
            sysFill.cornerRadius = 2
            metersHost.layer?.addSublayer(sysFill)
            self.sysMeterLayer = sysFill
        }

        // Optional webcam circle to the right of the timer.
        if let session = webcamSession {
            let circleSize: CGFloat = 44
            let circleRect = NSRect(
                x: 170, y: (size.height - circleSize) / 2,
                width: circleSize, height: circleSize
            )
            let host = NSView(frame: circleRect)
            host.wantsLayer = true
            host.layer?.cornerRadius = circleSize / 2
            host.layer?.masksToBounds = true
            host.layer?.borderWidth = 1.5
            host.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

            let prev = AVCaptureVideoPreviewLayer(session: session)
            prev.frame = host.bounds
            prev.videoGravity = .resizeAspectFill
            if let conn = prev.connection, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
            host.layer?.addSublayer(prev)
            bg.addSubview(host)
            self.webcamHostView = host
            self.webcamPreviewLayer = prev
        }

        // Big red Stop button — impossible to miss.
        let stopButtonWidth: CGFloat = 96
        let stopButton = NSButton(
            title: "Stop",
            target: self,
            action: #selector(stopAction)
        )
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .large
        stopButton.font = .systemFont(ofSize: 14, weight: .semibold)
        stopButton.keyEquivalent = "."
        stopButton.keyEquivalentModifierMask = [.command, .shift]
        stopButton.frame = NSRect(
            x: size.width - stopButtonWidth - 12,
            y: (size.height - 32) / 2,
            width: stopButtonWidth, height: 32
        )
        stopButton.contentTintColor = .systemRed
        // Add a custom background tint via wantsLayer.
        stopButton.wantsLayer = true
        bg.addSubview(stopButton)

        panel.contentView = bg
        panel.orderFrontRegardless()
        self.panel = panel
        self.startedAt = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
        elapsedLabel = nil; dotLayer = nil; startedAt = nil
        webcamHostView = nil; webcamPreviewLayer = nil
    }

    private func tick() {
        guard let s = startedAt, let label = elapsedLabel else { return }
        let dt = Int(Date().timeIntervalSince(s))
        label.stringValue = String(format: "REC  %d:%02d", dt / 60, dt % 60)

        if let levels = audioLevels {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let mic = micMeterLayer {
                let w = max(0, min(120, CGFloat(levels.mic) * 120))
                mic.frame = CGRect(x: 0, y: 7, width: w, height: 4)
            }
            if let sys = sysMeterLayer {
                let w = max(0, min(120, CGFloat(levels.system) * 120))
                sys.frame = CGRect(x: 0, y: 1, width: w, height: 4)
            }
            CATransaction.commit()
        }
    }

    @objc private func stopAction() {
        onStop?()
    }
}
