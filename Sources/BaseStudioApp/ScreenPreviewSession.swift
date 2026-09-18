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
    /// Screen Recording permission is missing/denied — the preview can't snap
    /// anything, so the UI should offer a Grant/Settings affordance instead of
    /// a silent black placeholder.
    @Published private(set) var screenPermissionNeeded = false
    /// The selected display/window couldn't be found in the shareable content.
    /// Surface "source unavailable / refresh" rather than silently previewing
    /// a *different* screen.
    @Published private(set) var sourceUnavailable = false

    /// Outcome of one snapshot attempt. Lets the @MainActor session update its
    /// published permission/availability flags without the nonisolated capture
    /// code touching actor state directly.
    enum Outcome {
        case image(CGImage)
        case noScreenPermission
        case sourceUnavailable
        case transient   // first frame in flight / one-off failure; keep prior state
    }

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
            let outcome = await Self.snapshot(for: captured)
            await self?.deliver(outcome)
        }
    }

    private func deliver(_ outcome: Outcome) {
        inFlight = false
        switch outcome {
        case .image(let cg):
            currentImage = NSImage(cgImage: cg, size: .zero)
            screenPermissionNeeded = false
            sourceUnavailable = false
        case .noScreenPermission:
            currentImage = nil
            screenPermissionNeeded = true
            sourceUnavailable = false
        case .sourceUnavailable:
            currentImage = nil
            sourceUnavailable = true
        case .transient:
            break   // keep whatever we last showed (placeholder or last frame)
        }
    }

    nonisolated private static func snapshot(for target: CaptureTarget) async -> Outcome {
        // Prefer SCScreenshotManager on macOS 14+. The legacy
        // `CGWindowListCreateImage` path is deprecated on Sonoma and returns
        // nil/black even when Screen Recording is granted — which is exactly
        // why the Home preview tile showed a dark placeholder instead of a live
        // thumbnail. Keep the CG path only as the macOS 13 fallback.
        if #available(macOS 14.0, *) {
            return await scSnapshot(for: target)
        }
        if let cg = legacySnapshot(for: target) { return .image(cg) }
        return .transient
    }

    @available(macOS 14.0, *)
    nonisolated private static func scSnapshot(for target: CaptureTarget) async -> Outcome {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // SCShareableContent throws when Screen Recording permission is
            // missing/denied. Report it so the UI can show a Grant affordance
            // instead of an unexplained black tile.
            BSLog.warn("Home preview: SCShareableContent failed (likely no screen-recording permission): \(error)")
            return .noScreenPermission
        }
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        switch target {
        case .display(let id):
            // Do NOT fall back to displays.first — silently previewing a
            // different screen than the one selected is worse than showing
            // "source unavailable".
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                return .sourceUnavailable
            }
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
            else { return .sourceUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: win)
            config.width = max(Int(win.frame.width), 2)
            config.height = max(Int(win.frame.height), 2)
        }
        do {
            let img = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return .image(img)
        } catch {
            BSLog.warn("Home preview screenshot failed: \(error)")
            return .transient
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
