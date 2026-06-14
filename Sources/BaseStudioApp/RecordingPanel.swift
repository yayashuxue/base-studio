import AVFoundation
import AppKit
import BaseStudioRecording
import Foundation

/// AppKit-side aliases for the Theme.swift palette. The `BS.Color.NS` enum
/// is the single source of truth — these typealiases just keep call sites
/// short. If you need a new colour here, add it to `BS.Color.NS` (and a
/// matching SwiftUI `BS.Color` token), not as a one-off literal in this file.
private typealias DockPaint = BS.Color.NS

/// Always-visible floating Stop dock.
///
/// Default position is **top-center**, just below the menu bar — the user
/// can drag it anywhere (panel is movable by background). Compact frosted
/// dock: pulsing red dot · monospaced timer · stacked audio meters ·
/// optional mirrored webcam circle · wide pill Stop button.
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

        // Layout constants.
        let height: CGFloat = 56
        let dotW: CGFloat = 12
        let timerW: CGFloat = 70
        let metersW: CGFloat = 96
        let webcamSize: CGFloat = 36
        let stopW: CGFloat = 76
        let gutter: CGFloat = 14   // horizontal padding inside the dock
        let gap: CGFloat = 12      // gap between zones

        // Compose width from zones.
        var width: CGFloat = gutter
        width += dotW + 6          // dot + small gap
        width += timerW + gap
        if levels != nil { width += metersW + gap }
        if hasWebcam { width += webcamSize + gap }
        width += stopW + gutter

        let size = NSSize(width: width, height: height)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Top-center, just below the menu bar. The user can drag it elsewhere
        // (panel.isMovableByWindowBackground = true) — this is just the
        // initial placement.
        let visible = NSScreen.main?.visibleFrame ?? screen
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 12
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

        // Frosted-dark dock surface. No coloured outline — the pulsing red
        // dot + timer carry the "live" signal; an outline reads as a stray
        // border when the panel sits over content.
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = BS.Radius.dock
        bg.layer?.masksToBounds = true

        // 1pt top inner highlight — "lit from above".
        let highlight = CAGradientLayer()
        highlight.frame = CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)
        highlight.colors = [
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ]
        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint   = CGPoint(x: 1, y: 0.5)
        bg.layer?.addSublayer(highlight)

        var x: CGFloat = gutter

        // Pulsing red dot.
        let dotContainer = NSView(frame: NSRect(x: x, y: (height - dotW) / 2, width: dotW, height: dotW))
        dotContainer.wantsLayer = true
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dotW, height: dotW), transform: nil)
        dot.fillColor = DockPaint.recordingRed.cgColor
        dot.shadowColor = DockPaint.recordingGlow.cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 6
        dot.shadowOffset = .zero
        dotContainer.layer?.addSublayer(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
        bg.addSubview(dotContainer)
        self.dotLayer = dot
        x += dotW + 6

        // Monospaced elapsed timer.
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = DockPaint.textPrimary
        label.frame = NSRect(x: x, y: (height - 20) / 2, width: timerW, height: 20)
        label.alignment = .left
        bg.addSubview(label)
        self.elapsedLabel = label
        x += timerW + gap

        // Two-row mic + system audio meters.
        if levels != nil {
            let metersHost = NSView(frame: NSRect(x: x, y: (height - 14) / 2, width: metersW, height: 14))
            metersHost.wantsLayer = true
            bg.addSubview(metersHost)

            let micBg = CALayer()
            micBg.frame = CGRect(x: 0, y: 8, width: metersW, height: 4)
            micBg.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            micBg.cornerRadius = 2
            metersHost.layer?.addSublayer(micBg)
            let micFill = CALayer()
            micFill.frame = CGRect(x: 0, y: 8, width: 0, height: 4)
            micFill.backgroundColor = DockPaint.meterMic.cgColor
            micFill.cornerRadius = 2
            metersHost.layer?.addSublayer(micFill)
            self.micMeterLayer = micFill

            let sysBg = CALayer()
            sysBg.frame = CGRect(x: 0, y: 2, width: metersW, height: 4)
            sysBg.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            sysBg.cornerRadius = 2
            metersHost.layer?.addSublayer(sysBg)
            let sysFill = CALayer()
            sysFill.frame = CGRect(x: 0, y: 2, width: 0, height: 4)
            sysFill.backgroundColor = DockPaint.meterSystem.cgColor
            sysFill.cornerRadius = 2
            metersHost.layer?.addSublayer(sysFill)
            self.sysMeterLayer = sysFill
            x += metersW + gap
        }

        // Optional mirrored webcam circle.
        if let session = webcamSession {
            let circleRect = NSRect(
                x: x, y: (height - webcamSize) / 2,
                width: webcamSize, height: webcamSize
            )
            let host = NSView(frame: circleRect)
            host.wantsLayer = true
            host.layer?.cornerRadius = webcamSize / 2
            host.layer?.masksToBounds = true
            host.layer?.borderWidth = 1
            host.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

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
            x += webcamSize + gap
        }

        // Wide pill Stop button. Custom-drawn so it can carry the warm-red
        // fill + 1pt highlight without fighting NSButton's default bezel.
        let stopButton = StudioStopButton(
            frame: NSRect(x: x, y: (height - 30) / 2, width: stopW, height: 30)
        )
        stopButton.target = self
        stopButton.action = #selector(stopAction)
        stopButton.keyEquivalent = "."
        stopButton.keyEquivalentModifierMask = [.command, .shift]
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
        micMeterLayer = nil; sysMeterLayer = nil
    }

    private func tick() {
        guard let s = startedAt, let label = elapsedLabel else { return }
        label.stringValue = BS.Format.mmss(Date().timeIntervalSince(s))

        if let levels = audioLevels {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let mic = micMeterLayer {
                let totalW: CGFloat = mic.superlayer?.bounds.width ?? 96
                let w = max(0, min(totalW, CGFloat(levels.mic) * totalW))
                mic.frame = CGRect(x: 0, y: 8, width: w, height: 4)
            }
            if let sys = sysMeterLayer {
                let totalW: CGFloat = sys.superlayer?.bounds.width ?? 96
                let w = max(0, min(totalW, CGFloat(levels.system) * totalW))
                sys.frame = CGRect(x: 0, y: 2, width: w, height: 4)
            }
            CATransaction.commit()
        }
    }

    @objc private func stopAction() {
        onStop?()
    }
}

// MARK: - Custom-drawn pill stop button

/// Wide red pill with "■ Stop", flat-fill, hover lifts to a slightly brighter
/// red. Custom-drawn (rather than relying on NSButton bezel) so the colour
/// stays consistent across macOS versions.
private final class StudioStopButton: NSButton {
    private var isHover: Bool = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { isHover = true }
    override func mouseExited(with event: NSEvent)  { isHover = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (isHover ? DockPaint.recordingHot : DockPaint.recordingRed).setFill()
        path.fill()

        // Top highlight — 1pt inner stroke fading from white-12% to clear.
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            path.addClip()
            let grad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    NSColor.white.withAlphaComponent(0.18).cgColor,
                    NSColor.white.withAlphaComponent(0).cgColor
                ] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: 0, y: bounds.maxY),
                end:   CGPoint(x: 0, y: bounds.midY),
                options: []
            )
            ctx.restoreGState()
        }

        // Label.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let label = NSAttributedString(string: "◼  Stop", attributes: attrs)
        let labelSize = label.size()
        label.draw(at: NSPoint(
            x: (bounds.width - labelSize.width) / 2,
            y: (bounds.height - labelSize.height) / 2 - 1
        ))
    }
}
