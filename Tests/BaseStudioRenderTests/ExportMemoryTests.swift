import AVFoundation
import BaseStudioCore
import Darwin
import XCTest
@testable import BaseStudioRender

/// Export must run in bounded memory. A 330 s live self-test with a busy
/// screen (6,400 frames) drove the export to ~40 GB and froze the Mac. Here: a
/// 10 s, 30 fps source where every frame changes (300 frames) exported at
/// 1080p, sampling the process footprint while it runs.
final class ExportMemoryTests: XCTestCase {

    static let ffmpeg: String? = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private let hostFirstPTS = CMTime(value: 1_234_567_890, timescale: 600)
    /// Short on purpose: if export leaks per frame, 300 frames already show it
    /// (~2.4 GB at 1080p) without endangering a 16 GB machine.
    private let durationSec = 10.0
    private let w = 1280, h = 720

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func testLongBusyExportStaysInBoundedMemory() async throws {
        guard let ffmpeg = Self.ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bs-mem-\(UUID().uuidString)", isDirectory: true)
        let bundle = tmp.appendingPathComponent("rec.basestudio", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=\(w)x\(h):rate=30:duration=\(durationSec)",
                       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(durationSec)",
                       "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "60",
                       "-c:a", "aac", "-ac", "2", bundle.appendingPathComponent("screen.mov").path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try writeMetadata(bundle.appendingPathComponent("metadata.json"))

        let baseline = Self.footprintMB()
        var peak = baseline
        let sampler = Task.detached {
            var localPeak = 0.0
            while !Task.isCancelled {
                localPeak = max(localPeak, Self.footprintMB())
                // Safety valve: never take the machine down while proving a leak.
                if localPeak - baseline > 3_000 {
                    print("EXPORT-MEMORY abort: +\(Int(localPeak - baseline)) MB")
                    exit(3)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return localPeak
        }
        _ = try await ExportPipeline().run(.init(
            project: makeProject(), bundleURL: bundle, outputURL: tmp.appendingPathComponent("out.mp4"),
            fps: 30, bitrate: 6_000_000, targetSize: (1920, 1080), audioMode: .systemOnly))
        sampler.cancel()
        peak = max(peak, await sampler.value)
        let growth = peak - baseline
        print("EXPORT-MEMORY baseline=\(Int(baseline)) MB peak=\(Int(peak)) MB growth=\(Int(growth)) MB")
        XCTAssertLessThan(growth, 400, "export memory grew \(Int(growth)) MB over 300 frames — not bounded")
    }

    private func makeProject() -> Project {
        let firstPTS = TimePoint(hostFirstPTS)
        let lastPTS = TimePoint(CMTimeAdd(hostFirstPTS, CMTime(seconds: durationSec, preferredTimescale: 600)))
        let screen = SourceClip(id: SourceID.screen, relativeMediaPath: "screen.mov",
                                widthPx: w, heightPx: h, firstPTS: firstPTS, sidecars: [])
        let segment = VideoSegment(sourceID: SourceID.screen, sourceIn: firstPTS, sourceOut: lastPTS,
                                   timelineIn: TimePoint(.zero))
        let bg = NodeInstance(instanceID: "bg_1", nodeType: BackgroundCompose.spec.id, bindings: [:], enabled: true)
        return Project(sources: [screen], videoTrack: VideoTrack(segments: [segment]),
                       nodeGraph: NodeGraph(nodes: [bg]), canvas: CanvasSpec(widthPx: 1920, heightPx: 1080),
                       timelineDuration: TimePoint(CMTime(seconds: durationSec, preferredTimescale: 600)))
    }

    private func writeMetadata(_ url: URL) throws {
        let firstPTS = TimePoint(hostFirstPTS)
        let lastPTS = TimePoint(CMTimeAdd(hostFirstPTS, CMTime(seconds: durationSec, preferredTimescale: 600)))
        let meta = RecordingMetadata(
            displayID: 1, widthPx: w, heightPx: h, pointScale: 2.0,
            displayOriginXPt: 0, displayOriginYPt: 0,
            displayWidthPt: Double(w) / 2, displayHeightPt: Double(h) / 2,
            firstVideoPTS: firstPTS, lastVideoPTS: lastPTS,
            sources: [SourceID.screen: SourceMediaInfo(firstVideoPTS: firstPTS, lastVideoPTS: lastPTS, widthPx: w, heightPx: h)],
            micFirstPTS: firstPTS)
        try JSONEncoder().encode(meta).write(to: url)
    }
}
