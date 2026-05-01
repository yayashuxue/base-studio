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

    public init(sampleHz: Int = 120) {
        self.sampleHz = sampleHz
    }

    public func start() {
        queue.sync {
            self.samples.removeAll(keepingCapacity: true)
            self.clicks.removeAll(keepingCapacity: true)
        }

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
        // Quartz query is thread-safe and gives us the same coordinate space as NSEvent.
        guard let loc = CGEvent(source: nil)?.location else { return }
        let pt = HostClock.now()
        samples.append(Sample(t: TimePoint(pt), x: Double(loc.x), y: Double(loc.y)))
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
