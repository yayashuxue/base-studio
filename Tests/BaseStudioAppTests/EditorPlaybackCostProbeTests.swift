import AppKit
import CoreMedia
import XCTest
@testable import BaseStudioApp

/// Manual probe (BS_EXISTING_BUNDLE): how long the editor takes to render
/// consecutive playback frames of a real take — the preview's picture lag.
final class EditorPlaybackCostProbeTests: XCTestCase {
    @MainActor
    func testRenderCostAtPlaybackRate() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        let start = Double(ProcessInfo.processInfo.environment["BS_PROBE_AT"] ?? "10") ?? 10
        var times: [Double] = []
        for i in 0..<48 {   // 2 s at 24 fps
            let pts = CMTime(seconds: start + Double(i) / 24, preferredTimescale: 600)
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = await editor.renderInternal(project: editor.project, at: pts)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let sorted = times.sorted()
        print(String(format: "RENDER-COST ms: median %.0f p90 %.0f max %.0f (budget 42)",
                     sorted[24], sorted[43], sorted.last!))
    }
}
