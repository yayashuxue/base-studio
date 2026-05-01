import AppKit
import BaseStudioRecording
import Combine
import CoreGraphics
import Foundation

/// Polls a low-fps thumbnail of the currently-selected capture target so the
/// HomeView preview tile shows a live representation of *what will be
/// recorded* — not just a static display glyph.
///
/// Implementation: one CG snapshot per ~1.2s on a background queue. We use
/// `CGDisplayCreateImage` / `CGWindowListCreateImage` (deprecated on macOS
/// 14 but still functional) to keep the code path on macOS 13 +. Switching
/// to `SCScreenshotManager` is a follow-up when we drop 13.
@MainActor
final class ScreenPreviewSession: ObservableObject {
    @Published private(set) var currentImage: NSImage?

    private var target: CaptureTarget?
    private var timer: Timer?
    private let interval: TimeInterval = 1.2
    private var inFlight = false

    func setTarget(_ newTarget: CaptureTarget?) {
        guard newTarget != target else { return }
        target = newTarget
        currentImage = nil
        if newTarget == nil {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard timer == nil else { return }
        captureOnce()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func captureOnce() {
        guard !inFlight, let target else { return }
        inFlight = true
        // Hop off the main actor for the CG call — `CGDisplayCreateImage`
        // can take 30–80ms on a 4K panel and we don't want to drop frames.
        let captured = target
        Task.detached(priority: .utility) { [weak self] in
            let cg = Self.snapshot(for: captured)
            await self?.deliver(cg)
        }
    }

    private func deliver(_ cg: CGImage?) {
        inFlight = false
        if let cg {
            currentImage = NSImage(cgImage: cg, size: .zero)
        }
    }

    nonisolated private static func snapshot(for target: CaptureTarget) -> CGImage? {
        switch target {
        case .display(let id):
            return CGDisplayCreateImage(CGDirectDisplayID(id))
        case .window(let id):
            return CGWindowListCreateImage(
                .null, .optionIncludingWindow,
                CGWindowID(id),
                [.boundsIgnoreFraming, .nominalResolution]
            )
        }
    }
}
