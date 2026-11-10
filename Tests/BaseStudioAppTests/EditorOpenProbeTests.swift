import AppKit
import XCTest
@testable import BaseStudioApp

/// Manual probe (BS_EXISTING_BUNDLE): time from opening a recording to the
/// first picture (quick still) and to the full-quality still.
final class EditorOpenProbeTests: XCTestCase {
    @MainActor private func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @MainActor
    func testTimeToFirstPicture() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let t0 = CFAbsoluteTimeGetCurrent()
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        let loaded = CFAbsoluteTimeGetCurrent() - t0
        editor.quickThenFullStill()
        var first: Double?, full: Double?
        while CFAbsoluteTimeGetCurrent() - t0 < 30, full == nil {
            if first == nil, editor.renderedImage != nil { first = CFAbsoluteTimeGetCurrent() - t0 }
            if editor.renderedImage != nil, editor.renderedImageScale == 1 { full = CFAbsoluteTimeGetCurrent() - t0 }
            await spin(0.02)
        }
        print(String(format: "OPEN load %.2f s, first picture %.2f s, full quality %.2f s", loaded, first ?? -1, full ?? -1))
        XCTAssertNotNil(first)
    }
}
