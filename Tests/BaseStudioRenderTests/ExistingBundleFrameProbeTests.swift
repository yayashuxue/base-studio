import AVFoundation
import BaseStudioCore
import XCTest
@testable import BaseStudioRender

/// Manual probe: export 3 s of an existing recording (from BS_PROBE_AT
/// seconds) through the real pipeline, as-is and with the background node
/// off, to /tmp/bs-probe-{as-is,no-bg}.mp4. Skipped unless BS_EXISTING_BUNDLE.
final class ExistingBundleFrameProbeTests: XCTestCase {
    func testExportShortSlice() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else {
            throw XCTSkip("Set BS_EXISTING_BUNDLE for the local probe")
        }
        let at = Double(ProcessInfo.processInfo.environment["BS_PROBE_AT"] ?? "5") ?? 5
        let bundle = ProjectBundle(url: URL(fileURLWithPath: path, isDirectory: true))
        var project = try ProjectIO.load(from: bundle)
        let seg = try XCTUnwrap(project.videoTrack.segments.first)
        let start = CMTimeAdd(seg.sourceIn.cmTime, CMTime(seconds: at, preferredTimescale: 600))
        project.videoTrack.segments[0].sourceIn = TimePoint(start)
        project.videoTrack.segments[0].sourceOut = TimePoint(CMTimeAdd(start, CMTime(seconds: 3, preferredTimescale: 600)))
        project.timelineDuration = TimePoint(CMTime(seconds: 3, preferredTimescale: 600))
        // Keep zoom/speed regions overlapping the slice (shifted into it)
        // with BS_PROBE_KEEP_REGIONS=1; otherwise drop them.
        if ProcessInfo.processInfo.environment["BS_PROBE_KEEP_REGIONS"] == "1" {
            project.zoomRegions = project.zoomRegions.compactMap { r in
                var r = r
                let a = r.timelineIn.seconds - at, b = r.timelineOut.seconds - at
                guard b > 0, a < 3 else { return nil }
                r.timelineIn = TimePoint(CMTime(seconds: max(0, a), preferredTimescale: 600))
                r.timelineOut = TimePoint(CMTime(seconds: min(3, b), preferredTimescale: 600))
                return r
            }
        } else {
            project.zoomRegions = []
        }

        for (label, bgOn) in [("as-is", true), ("no-bg", false)] {
            var p = project
            for i in p.nodeGraph.nodes.indices where p.nodeGraph.nodes[i].nodeType == "background_compose" {
                p.nodeGraph.nodes[i].enabled = bgOn
            }
            let out = URL(fileURLWithPath: "/tmp/bs-probe-\(label).mp4")
            try? FileManager.default.removeItem(at: out)
            _ = try await ExportPipeline().run(.init(project: p, bundleURL: bundle.url, outputURL: out,
                                                     fps: 30, bitrate: 6_000_000, audioMode: .mute))
        }
    }
}
