import AppKit
import AVFoundation
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioRender

/// Manual probe (BS_EXISTING_BUNDLE): build the editor's new playback item
/// for a real take, pull frames through PreviewCompositor and time them;
/// writes /tmp/bs-preview-frame.png. Checks the item's duration matches the
/// TimeMap (speed regions included).
final class PreviewPlaybackProbeTests: XCTestCase {
    @MainActor
    func testPlaybackItemOnRealTake() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        let audio = await AudioPlan.sources(project: editor.project, bundleURL: editor.bundleURL, meta: editor.recordingMeta)
        let ctx = PreviewPlayback.Context(project: editor.project, timeMap: editor.timeMap,
                                          primary: editor.primarySource, sidecars: editor.sidecars, backgroundImage: nil)
        let item = try await PreviewPlayback.makeItem(ctx, bundleURL: editor.bundleURL, audio: audio)
        let dur = try await item.asset.load(.duration).seconds
        print("PREVIEW item duration \(dur) vs timeline \(editor.timelineDurationSec)")
        XCTAssertEqual(dur, editor.timelineDurationSec, accuracy: 0.2)

        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let at = Double(ProcessInfo.processInfo.environment["BS_PROBE_AT"] ?? "20") ?? 20
        var ms: [Double] = []
        for i in 0..<30 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = try await gen.image(at: CMTime(seconds: at + Double(i) / 30, preferredTimescale: 600)).image
            ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if i == 0 {
                let rep = NSBitmapImageRep(cgImage: img)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bs-preview-frame.png"))
            }
        }
        let s = ms.sorted()
        print(String(format: "PREVIEW compositor frame ms: median %.0f p90 %.0f (random access via generator; playback decodes sequentially)", s[15], s[27]))
    }
}
