import AppKit
import SwiftUI
import XCTest

/// Probe: can we render SwiftUI to a PNG offscreen (NSHostingView +
/// cacheDisplay), with no Accessibility and no real project/navigation? If yes,
/// this is the seam for headless editor before/after screenshots (小o's plan).
/// If it produces a blank/failed image headlessly, that's the "env dependency"
/// to report rather than refactoring the theme for screenshots.
final class SnapshotProbeTests: XCTestCase {

    @MainActor
    func testRendersSwiftUIToPNGOffscreen() throws {
        let view = ZStack {
            LinearGradient(colors: [.blue, .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Text("Base Studio").font(.system(size: 28, weight: .bold))
                Text("offscreen snapshot probe").font(.system(size: 14))
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.9))
                    .frame(width: 220, height: 90)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 480, height: 300)

        let data = try Self.renderPNG(view, size: CGSize(width: 480, height: 300))
        let url = URL(fileURLWithPath: "/tmp/snapshot-probe.png")
        try data.write(to: url)
        // A real render is well over a few hundred bytes; a blank/failed one is tiny.
        XCTAssertGreaterThan(data.count, 2000, "offscreen PNG suspiciously small — render may be blank")
    }

    /// Render any SwiftUI view to PNG via an offscreen NSHostingView. Runs the
    /// layout pass, then caches the layer into a bitmap rep.
    @MainActor
    static func renderPNG<V: View>(_ view: V, size: CGSize) throws -> Data {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap rep"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "snapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "no PNG data"])
        }
        return data
    }
}
