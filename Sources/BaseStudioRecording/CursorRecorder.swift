import AppKit
import BaseStudioCore
import CoreGraphics
import CoreMedia
import Foundation

/// Sidecar stream for cursor + clicks.
///
/// Critically: timestamps come from `HostClock.now()`, the same clock that produces
/// video PTSes from ScreenCaptureKit. Without this, auto-zoom-on-click will trigger
/// at the wrong moment forever (PRD §6).
public final class CursorRecorder: @unchecked Sendable {

    public struct Sample: Codable {
        public let t: TimePoint
        public let x: Double          // global screen coords (logical points)
        public let y: Double
    }

    public struct ClickEvent: Codable {
        public let t: TimePoint
        public let x: Double
        public let y: Double
        public let button: String     // "left" | "right"
        public let phase: String      // "down" | "up"
    }

    public struct Sidecar: Codable {
        public let samples: [Sample]
        public let clicks: [ClickEvent]
        public let sampleHz: Int
    }

    private let sampleHz: Int
    private let queue = DispatchQueue(label: "BaseStudio.Cursor")
    private var timer: DispatchSourceTimer?
    private var clickMonitor: Any?
    private var samples: [Sample] = []
    private var clicks: [ClickEvent] = []
    /// Height of the global CG screen space, captured once at start. Used to
    /// flip `CGEvent.location` (top-left, increasing downward) into NSEvent
    /// coords (bottom-left, increasing upward) so cursor samples and click
    /// events live in the same coordinate space — which `SidecarLoader`
    /// assumes. Without this flip, cursor follow renders mirrored vertically.
    private var cgFlipY: CGFloat = 0

    public init(sampleHz: Int = 120) {
        self.sampleHz = sampleHz
    }

    public func start() {
        queue.sync {
            self.samples.removeAll(keepingCapacity: true)
            self.clicks.removeAll(keepingCapacity: true)
        }
        // Cache main display height (points) for the CG→NS Y-flip used by
        // `tick()`. NSScreen access must be on the main thread; safe here
        // because `start()` is called from the main actor.
        let mainHeightPt = NSScreen.screens.first?.frame.height ?? 0
        queue.sync { self.cgFlipY = mainHeightPt }

        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / max(1, sampleHz)))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        // Global monitor: callback delivered on main run loop.
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        ]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleClick(event)
        }
    }

    public func stop() -> Sidecar {
        timer?.cancel()
        timer = nil
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        return queue.sync {
            Sidecar(samples: samples, clicks: clicks, sampleHz: sampleHz)
        }
    }

    // MARK: - private

    private func tick() {
        // CGEvent.location is top-left origin (CG flipped). Click events
        // come from NSEvent.mouseLocation which is bottom-left. SidecarLoader
        // assumes one consistent space (bottom-left, NSEvent-style), so we
        // flip Y here at capture time.
        guard let loc = CGEvent(source: nil)?.location else { return }
        let pt = HostClock.now()
        let yNS = Double(cgFlipY) - Double(loc.y)
        samples.append(Sample(t: TimePoint(pt), x: Double(loc.x), y: yNS))
    }

    private func handleClick(_ e: NSEvent) {
        let pt = HostClock.now()
        let loc = NSEvent.mouseLocation
        let isLeft = (e.type == .leftMouseDown || e.type == .leftMouseUp)
        let isDown = (e.type == .leftMouseDown || e.type == .rightMouseDown)
        let ev = ClickEvent(
            t: TimePoint(pt),
            x: Double(loc.x), y: Double(loc.y),
            button: isLeft ? "left" : "right",
            phase: isDown ? "down" : "up"
        )
        queue.async { [weak self] in self?.clicks.append(ev) }
    }
}
