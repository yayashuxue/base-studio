import AppKit
import BaseStudioCore
import BaseStudioRecording
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

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
            let cg = await Self.snapshot(for: captured)
            await self?.deliver(cg)
        }
    }

    private func deliver(_ cg: CGImage?) {
        inFlight = false
        if let cg {
            currentImage = NSImage(cgImage: cg, size: .zero)
        }
    }

    nonisolated private static func snapshot(for target: CaptureTarget) async -> CGImage? {
        // Prefer SCScreenshotManager on macOS 14+. The legacy
        // `CGWindowListCreateImage` path is deprecated on Sonoma and returns
        // nil/black even when Screen Recording is granted — which is exactly
        // why the Home preview tile showed a dark placeholder instead of a live
        // thumbnail. Keep the CG path only as the macOS 13 fallback.
        if #available(macOS 14.0, *) {
            if let img = await scSnapshot(for: target) { return img }
            // Fall through: on a permission edge case SC returns nil; the
            // legacy call may still succeed on some setups.
        }
        return legacySnapshot(for: target)
    }

    @available(macOS 14.0, *)
    nonisolated private static func scSnapshot(for target: CaptureTarget) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let filter: SCContentFilter
            let config = SCStreamConfiguration()
            switch target {
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id })
                        ?? content.displays.first else { return nil }
                // Exclude our own app so the tile shows what will be recorded,
                // not an infinite mirror of Base Studio inside itself.
                let ours = content.applications.filter {
                    $0.processID == ProcessInfo.processInfo.processIdentifier
                }
                filter = SCContentFilter(
                    display: display, excludingApplications: ours, exceptingWindows: []
                )
                config.width = max(display.width, 2)
                config.height = max(display.height, 2)
            case .window(let id):
                guard let win = content.windows.first(where: { $0.windowID == CGWindowID(id) })
                else { return nil }
                filter = SCContentFilter(desktopIndependentWindow: win)
                config.width = max(Int(win.frame.width), 2)
                config.height = max(Int(win.frame.height), 2)
            }
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            BSLog.warn("Home preview screenshot failed: \(error)")
            return nil
        }
    }

    nonisolated private static func legacySnapshot(for target: CaptureTarget) -> CGImage? {
        switch target {
        case .display:
            // Capture everything *below* Base Studio's main window so the
            // preview tile shows what would actually be recorded — without
            // turning into an infinite mirror of the app inside itself.
            if let ourWindow = ourMainWindowID() {
                return CGWindowListCreateImage(
                    .null, .optionOnScreenBelowWindow,
                    ourWindow,
                    [.boundsIgnoreFraming, .nominalResolution]
                )
            }
            return nil
        case .window(let id):
            return CGWindowListCreateImage(
                .null, .optionIncludingWindow,
                CGWindowID(id),
                [.boundsIgnoreFraming, .nominalResolution]
            )
        }
    }

    /// Lowest-z-order on-screen normal-layer window owned by our process —
    /// effectively the main app window. Used as the anchor for "capture
    /// everything below this window."
    nonisolated private static func ourMainWindowID() -> CGWindowID? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let opts: CGWindowListOption = [.optionOnScreenOnly]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: AnyObject]] else { return nil }
        // Layer 0 = normal app window. Higher layers = panels, status bar, etc.
        let mine = info.first { entry in
            ((entry[kCGWindowOwnerPID as String] as? Int32) ?? -1) == pid &&
            ((entry[kCGWindowLayer as String] as? Int) ?? -1) == 0
        }
        return mine?[kCGWindowNumber as String] as? CGWindowID
    }
}
