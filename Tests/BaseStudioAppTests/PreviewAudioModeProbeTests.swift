import AppKit
import AVFoundation
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioRender
@testable import BaseStudioCore

/// Manual probe (BS_EXISTING_BUNDLE): the Audio choice (Both / Mic /
/// System / Mute) must change what the preview plays AND what export
/// writes. Counts audio tracks in the preview item and the exported file
/// (3 s slice) and measures their level.
final class PreviewAudioModeProbeTests: XCTestCase {
    @MainActor
    func testAudioChoiceReachesPreviewAndExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        let modes: [(String, ExportPipeline.AudioMode, Int)] = [("both", .both, 2), ("mic", .micOnly, 1),
                                                                 ("system", .systemOnly, 1), ("mute", .mute, 0)]
        for (name, mode, expected) in modes {
            let sources = await AudioPlan.sources(project: editor.project, bundleURL: editor.bundleURL,
                                                  meta: editor.recordingMeta, mode: mode)
            let ctx = PreviewPlayback.Context(project: editor.project, timeMap: editor.timeMap,
                                              primary: editor.primarySource, sidecars: editor.sidecars, backgroundImage: nil)
            let item = try await PreviewPlayback.makeItem(ctx, bundleURL: editor.bundleURL, audio: sources)
            let previewTracks = try await item.asset.loadTracks(withMediaType: .audio).count

            var p = editor.project
            let seg = p.videoTrack.segments[0]
            let start = CMTimeAdd(seg.sourceIn.cmTime, CMTime(seconds: 20, preferredTimescale: 600))
            p.videoTrack.segments[0].sourceIn = TimePoint(start)
            p.videoTrack.segments[0].sourceOut = TimePoint(CMTimeAdd(start, CMTime(seconds: 3, preferredTimescale: 600)))
            p.timelineDuration = TimePoint(CMTime(seconds: 3, preferredTimescale: 600))
            p.zoomRegions = []
            let out = URL(fileURLWithPath: "/tmp/bs-audiomode-\(name).mp4")
            try? FileManager.default.removeItem(at: out)
            _ = try await ExportPipeline().run(.init(project: p, bundleURL: editor.bundleURL, outputURL: out,
                                                     fps: 15, bitrate: 2_000_000, audioMode: mode))
            let exportTracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).count
            print("AUDIOMODE \(name): preview sources \(sources.count), preview audio tracks \(previewTracks), export audio tracks \(exportTracks)")
            XCTAssertEqual(previewTracks, expected, name)
            XCTAssertEqual(exportTracks, min(expected, 1), name)   // export mixes to one track
        }
    }
}
