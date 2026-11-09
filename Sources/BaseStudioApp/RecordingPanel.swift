import AppKit
import BaseStudioRecording
import Foundation

/// AppKit-side aliases for the Theme.swift palette. The `BS.Color.NS` enum
/// is the single source of truth — these typealiases just keep call sites
/// short. If you need a new colour here, add it to `BS.Color.NS` (and a
/// matching SwiftUI `BS.Color` token), not as a one-off literal in this file.
private typealias DockPaint = BS.Color.NS

/// Loom-style recording control bar: a slim vertical bar, by default on the
/// right edge, draggable anywhere; it remembers where it was left. Pulsing
/// dot · timer · audio meters · Restart · Stop. Shown for every recording —
/// the menu-bar item can be hidden by the notch, so this is the one Stop
/// that is always visible. Base Studio's windows are left out of display
/// capture, so the bar never appears in the video.
@MainActor
final class RecordingPanel {
    private(set) var panel: NSPanel?
    private var elapsedLabel: NSTextField?
    private var timer: Timer?
    private var startedAt: Date?
    private weak var audioLevels: AudioLevels?
    private var micMeterLayer: CALayer?
    private var sysMeterLayer: CALayer?

    var onStop: (() -> Void)?
    var onRetake: (() -> Void)?

    private static let width: CGFloat = 56
    private static let originKey = "RecordingControlBar.origin"
    private static let meterW: CGFloat = 32

    /// `stopKey` / `restartKey`: shortcut text to show, only if registered.
    func show(levels: AudioLevels? = nil, stopKey: String? = nil, restartKey: String? = nil) {
        self.audioLevels = levels
        guard panel == nil else { return }

        let w = Self.width
        let h: CGFloat = 12 + 10 + 6 + 16 + 10 + 8 + 14 + 32 + 8 + 36 + 12
        let size = NSSize(width: w, height: h)

        let panel = NSPanel(
            contentRect: NSRect(origin: Self.initialOrigin(for: size), size: size),
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

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.appearance = NSAppearance(named: .darkAqua)
        // Round the vibrancy itself with a mask image: a layer cornerRadius
        // only clips the content, the blur stays square and shows as a box
        // around the rounded bar (julie, 11/8).
        bg.maskImage = Self.pillMask(radius: w / 2)

        // Laid out top-down; AppKit's y grows upward.
        var y = h - 12

        // Pulsing red dot.
        y -= 10
        let dotHost = NSView(frame: NSRect(x: (w - 10) / 2, y: y, width: 10, height: 10))
        dotHost.wantsLayer = true
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
        dot.fillColor = DockPaint.recordingRed.cgColor
        dot.shadowColor = DockPaint.recordingGlow.cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 5
        dot.shadowOffset = .zero
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
        dotHost.layer?.addSublayer(dot)
        bg.addSubview(dotHost)

        // Timer.
        y -= 6 + 16
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: y, width: w, height: 16)
        bg.addSubview(label)
        self.elapsedLabel = label

        // Mic (top) + system audio meters.
        y -= 10 + 8
        if levels != nil {
            let host = NSView(frame: NSRect(x: (w - Self.meterW) / 2, y: y, width: Self.meterW, height: 8))
            host.wantsLayer = true
            for (row, color) in [(5, DockPaint.meterMic), (0, DockPaint.meterSystem)] {
                let track = CALayer()
                track.frame = CGRect(x: 0, y: CGFloat(row), width: Self.meterW, height: 3)
                track.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
                track.cornerRadius = 1.5
                host.layer?.addSublayer(track)
                let fill = CALayer()
                fill.frame = CGRect(x: 0, y: CGFloat(row), width: 0, height: 3)
                fill.backgroundColor = color.cgColor
                fill.cornerRadius = 1.5
                host.layer?.addSublayer(fill)
                if row == 5 { micMeterLayer = fill } else { sysMeterLayer = fill }
            }
            bg.addSubview(host)
        }

        // Restart.
        y -= 14 + 32
        let retake = CircleIconButton(
            frame: NSRect(x: (w - 32) / 2, y: y, width: 32, height: 32),
            symbol: "arrow.counterclockwise", fill: NSColor.white.withAlphaComponent(0.14),
            hover: NSColor.white.withAlphaComponent(0.24)
        )
        retake.toolTip = restartKey.map { "Restart  (\($0))" } ?? "Restart"
        retake.target = self
        retake.action = #selector(retakeAction)
        bg.addSubview(retake)

        // Stop.
        y -= 8 + 36
        let stop = CircleIconButton(
            frame: NSRect(x: (w - 36) / 2, y: y, width: 36, height: 36),
            symbol: "stop.fill", fill: DockPaint.recordingRed, hover: DockPaint.recordingHot
        )
        stop.toolTip = stopKey.map { "Stop  (\($0))" } ?? "Stop"
        stop.target = self
        stop.action = #selector(stopAction)
        bg.addSubview(stop)

        panel.contentView = bg
        panel.orderFrontRegardless()
        panel.invalidateShadow()   // shadow follows the pill, not the frame
        self.panel = panel
        self.startedAt = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func hide() {
        if let origin = panel?.frame.origin {
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originKey)
        }
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
        elapsedLabel = nil; startedAt = nil
        micMeterLayer = nil; sysMeterLayer = nil
    }

    private static func pillMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    /// Where the user left it, if that spot is still on a screen; else the
    /// right edge of the main screen, vertically centred.
    private static func initialOrigin(for size: NSSize) -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(s)
            let frame = NSRect(origin: p, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return p }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.midY - size.height / 2)
    }

    private func tick() {
        guard let s = startedAt, let label = elapsedLabel else { return }
        label.stringValue = BS.Format.mmss(Date().timeIntervalSince(s))
        guard let levels = audioLevels else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let mic = micMeterLayer {
            mic.frame.size.width = max(0, min(Self.meterW, CGFloat(levels.mic) * Self.meterW))
        }
        if let sys = sysMeterLayer {
            sys.frame.size.width = max(0, min(Self.meterW, CGFloat(levels.system) * Self.meterW))
        }
        CATransaction.commit()
    }

    @objc private func stopAction() { onStop?() }
    @objc private func retakeAction() { onRetake?() }
}

// MARK: - Round icon button

/// Flat round button with an SF Symbol; hover brightens the fill.
private final class CircleIconButton: NSButton {
    private let fill: NSColor
    private let hoverFill: NSColor
    private let symbol: String
    private var isHover = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, symbol: String, fill: NSColor, hover: NSColor) {
        self.fill = fill
        self.hoverFill = hover
        self.symbol = symbol
        super.init(frame: frame)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { isHover = true }
    override func mouseExited(with event: NSEvent) { isHover = false }

    override func draw(_ dirtyRect: NSRect) {
        (isHover ? hoverFill : fill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let config = NSImage.SymbolConfiguration(pointSize: bounds.height * 0.38, weight: .bold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2,
                               width: img.size.width, height: img.size.height))
    }
}
