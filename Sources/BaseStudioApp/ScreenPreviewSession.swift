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

    // Cached SCContentFilter for the current target. Building it requires a
    // full `SCShareableContent` enumeration (~100-500ms) — doing that every
    // 1.2s tick was why the preview felt slow and stalled on every source
    // switch. We resolve the filter ONCE per target and reuse it for the cheap
    // per-tick `SCScreenshotManager.captureImage`. `SCContentFilter` tracks a
    // window by identity, so it stays valid as the window moves; the cache is
    // dropped on target change (setTarget).
    private var cachedFilterTarget: CaptureTarget?
    private var cachedFilter: SCContentFilter?
    private var cachedConfig: SCStreamConfiguration?
    /// A slow filter build is already running — don't queue a second one.
    private var buildingFilter = false

    /// Bumped on every source change. A capture Task carries the generation it
    /// was started under; a frame that arrives after the source changed is
    /// DROPPED instead of overwriting the new source's image (the "stale
    /// request paints the old tab" flicker).
    private var generation = 0
    /// Recent end-to-end request→published latencies (ms) for p50/max logging.
    private var latencies: [Int] = []

    enum FilterBuild {
        case ready(SCContentFilter, SCStreamConfiguration)
        case noScreenPermission
        case sourceUnavailable
    }

    func setTarget(_ newTarget: CaptureTarget?) {
        guard newTarget != target else { return }
        target = newTarget
        currentImage = nil
        // New source: bump the generation so any in-flight capture from the old
        // source is dropped on arrival instead of painting the wrong tab.
        generation += 1
        // Drop the cached filter so the next tick rebuilds for the new source.
        cachedFilterTarget = nil
        cachedFilter = nil
        cachedConfig = nil
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
        guard let target else { return }

        if #available(macOS 14.0, *) {
            // Fast path: reuse the cached filter and just grab a frame.
            if cachedFilterTarget == target, let filter = cachedFilter, let config = cachedConfig {
                guard !inFlight else { return }
                inFlight = true
                captureWith(filter: filter, config: config, gen: generation)
                return
            }
            // Slow path: resolve the filter once for this target, cache it,
            // then take the first frame. Guarded so ticks don't pile up
            // multiple SCShareableContent enumerations while one is running.
            guard !buildingFilter else { return }
            buildingFilter = true
            let captured = target
            Task { [weak self] in
                let built = await Self.buildFilter(for: captured)
                guard let self else { return }
                self.buildingFilter = false
                // Target changed while we were building — discard.
                guard self.target == captured else { return }
                switch built {
                case .ready(let filter, let config):
                    self.cachedFilterTarget = captured
                    self.cachedFilter = filter
                    self.cachedConfig = config
                    guard !self.inFlight else { return }
                    self.inFlight = true
                    self.captureWith(filter: filter, config: config, gen: self.generation)
                case .noScreenPermission:
                    self.deliver(.noScreenPermission)
                case .sourceUnavailable:
                    self.deliver(.sourceUnavailable)
                }
            }
            return
        }

        // macOS 13 fallback: legacy CG snapshot each tick.
        guard !inFlight else { return }
        inFlight = true
        let captured = target
        let gen = generation
        let requestedAt = Date()
        Task.detached(priority: .utility) { [weak self] in
            let cg = Self.legacySnapshot(for: captured)
            await self?.deliver(cg != nil ? .image(cg!) : .transient, gen: gen, requestedAt: requestedAt)
        }
    }

    @available(macOS 14.0, *)
    private func captureWith(filter: SCContentFilter, config: SCStreamConfiguration, gen: Int) {
        let requestedAt = Date()
        Task.detached(priority: .utility) { [weak self] in
            do {
                let t0 = Date()
                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                // Cheap per-frame capture (cached filter) — only flag if slow.
                if ms > 120 { BSLog.warn("preview frame slow: \(ms)ms") }
                await self?.deliver(.image(img), gen: gen, requestedAt: requestedAt)
            } catch {
                BSLog.warn("Home preview screenshot failed: \(error)")
                await self?.deliver(.transient, gen: gen, requestedAt: requestedAt)
            }
        }
    }

    private func deliver(_ outcome: Outcome, gen: Int = -1, requestedAt: Date? = nil) {
        inFlight = false
        // Drop frames from a source the user already switched away from.
        if gen >= 0, gen != generation {
            BSLog.info("preview: dropped stale frame (gen \(gen) != \(generation))")
            return
        }
        if case .image = outcome, let requestedAt {
            let ms = Int(Date().timeIntervalSince(requestedAt) * 1000)
            latencies.append(ms)
            if latencies.count >= 8 {
                let sorted = latencies.sorted()
                let p50 = sorted[sorted.count / 2]
                let mx = sorted.last ?? ms
                BSLog.info("preview end-to-end latency: p50=\(p50)ms max=\(mx)ms (n=\(latencies.count))")
                latencies.removeAll(keepingCapacity: true)
            }
        }
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

    /// Resolve the `SCContentFilter` + config for a target via a single
    /// `SCShareableContent` enumeration. Only called when the target changes
    /// (or on first tick), NOT on every frame — that's the whole point of the
    /// cache. The per-tick screenshot uses the cached result.
    @available(macOS 14.0, *)
    nonisolated private static func buildFilter(for target: CaptureTarget) async -> FilterBuild {
        let content: SCShareableContent
        let t0 = Date()
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            // This is the expensive call the cache exists to amortize; log it so
            // first-load / source-switch recovery time is measurable.
            BSLog.info("preview filter built (SCShareableContent) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        } catch {
            // SCShareableContent throws when Screen Recording permission is
            // missing/denied. Report it so the UI can show a Grant affordance
            // instead of an unexplained black tile.
            BSLog.warn("Home preview: SCShareableContent failed (likely no screen-recording permission): \(error)")
            return .noScreenPermission
        }
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
            let filter = SCContentFilter(
                display: display, excludingApplications: ours, exceptingWindows: []
            )
            config.width = max(display.width, 2)
            config.height = max(display.height, 2)
            return .ready(filter, config)
        case .window(let id):
            guard let win = content.windows.first(where: { $0.windowID == CGWindowID(id) })
            else { return .sourceUnavailable }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            config.width = max(Int(win.frame.width), 2)
            config.height = max(Int(win.frame.height), 2)
            return .ready(filter, config)
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
