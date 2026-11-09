import AppKit
import QuartzCore
import Darwin
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
        // Real playback: an AVPlayer (muted) plays 6 s; count distinct frames
        // the item delivers — what the editor would show per second.
        do {
            let playItem = try await PreviewPlayback.makeItem(ctx, bundleURL: editor.bundleURL, audio: audio)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            playItem.add(output)
            let player = AVPlayer(playerItem: playItem)
            player.isMuted = true
            await player.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            for _ in 0..<100 where playItem.status != .readyToPlay { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(playItem.status, .readyToPlay, "item error: \(String(describing: playItem.error))")
            let before = PreviewCompositor.framesComposed
            player.play()
            let t0 = CFAbsoluteTimeGetCurrent()
            var shown = 0
            while CFAbsoluteTimeGetCurrent() - t0 < 6 {
                let now = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: now), output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil { shown += 1 }
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            let advanced = player.currentTime().seconds - at
            player.pause()
            print(String(format: "PREVIEW real playback: %.1f fps shown, %.1f fps composed, clock advanced %.2f s in 6 s, item error %@, compositor error %@",
                         Double(shown) / 6, Double(PreviewCompositor.framesComposed - before) / 6, advanced,
                         String(describing: playItem.error), PreviewCompositor.lastError ?? "none"))
        }
        let s = ms.sorted()
        // Memory: 30 s of continuous playback frames through the compositor,
        // then 40 random seeks; footprint must not keep climbing.
        func footprintMB() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
        }
        let base = footprintMB()
        let reader = try AVAssetReader(asset: item.asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: at, preferredTimescale: 600), duration: CMTime(seconds: 30, preferredTimescale: 600))
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await item.asset.loadTracks(withMediaType: .video),
                                                       videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = item.videoComposition
        reader.add(vOut)
        XCTAssertTrue(reader.startReading())
        let seqStart = CFAbsoluteTimeGetCurrent()
        var frames = 0, peak = base, samples: [Int] = []
        while let sb = vOut.copyNextSampleBuffer() {
            _ = sb; frames += 1
            if frames % 60 == 0 { let m = footprintMB(); peak = max(peak, m); samples.append(m)
                if m > 1500 { XCTFail("footprint \(m) MB > 1500 MB"); break } }
        }
        let seqFPS = Double(frames) / (CFAbsoluteTimeGetCurrent() - seqStart)
        print(String(format: "PREVIEW per-frame: graph build %.1f ms, GPU draw %.1f ms (avg over composed frames)",
                     PreviewCompositor.buildMs / Double(max(1, PreviewCompositor.framesComposed)),
                     PreviewCompositor.drawMs / Double(max(1, PreviewCompositor.framesComposed))))
        print(String(format: "PREVIEW sequential compositor throughput: %.1f fps (needs 30)", seqFPS))
        for _ in 0..<40 {
            let t = CMTime(seconds: Double.random(in: 0..<max(1, dur - 1)), preferredTimescale: 600)
            _ = try? await gen.image(at: t)
            peak = max(peak, footprintMB())
        }
        print("PREVIEW memory: base \(base) MB, peak \(peak) MB over \(frames) frames + 40 seeks; per-2s samples \(samples)")
        XCTAssertEqual(reader.status, .completed)
        XCTAssertLessThan(peak - base, 600, "preview playback memory grew \(peak - base) MB")
        print(String(format: "PREVIEW compositor frame ms: median %.0f p90 %.0f (random access via generator; playback decodes sequentially)", s[15], s[27]))
    }
}
