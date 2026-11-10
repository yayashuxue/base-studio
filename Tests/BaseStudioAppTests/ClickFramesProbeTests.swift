import AppKit
import AVFoundation
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioRender

/// Manual probe (BS_EXISTING_BUNDLE, BS_PROBE_TIMES="5.06,11.93"): for each
/// click time, preview frames (Performance 0.4× and Full 1×) before, at and
/// after the click → /tmp/click-<t>-<when>-<variant>.png
final class ClickFramesProbeTests: XCTestCase {
    @MainActor
    func testPreviewFramesAroundClicks() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        let times = (ProcessInfo.processInfo.environment["BS_PROBE_TIMES"] ?? "5.06").split(separator: ",").compactMap { Double($0) }
        let ctx = PreviewPlayback.Context(project: editor.project, timeMap: editor.timeMap, primary: editor.primarySource,
                                          sidecars: editor.sidecars, backgroundImage: nil)
        for (variant, scale) in [("perf", 0.4), ("full", 1.0)] {
            let item = try await PreviewPlayback.makeItem(ctx, bundleURL: editor.bundleURL, audio: [], scale: scale)
            let gen = AVAssetImageGenerator(asset: item.asset)
            gen.videoComposition = item.videoComposition
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            for t in times {
                for (when, dt) in [("before", -0.5), ("at", 0.08), ("after", 0.6)] {
                    // Clicks are in source time; timeline ≈ source here (no cuts/speed before).
                    let tl = editor.timeMap.timelineSec(atSource: t + dt) ?? (t + dt)
                    let img = try await gen.image(at: CMTime(seconds: tl, preferredTimescale: 600)).image
                    let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
                    try png.write(to: URL(fileURLWithPath: String(format: "/tmp/click-%.2f-%@-%@.png", t, when, variant)))
                }
            }
        }
    }
}
