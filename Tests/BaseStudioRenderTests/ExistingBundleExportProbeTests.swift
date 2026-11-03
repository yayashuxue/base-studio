import AVFoundation
import BaseStudioCore
import Darwin
import XCTest
@testable import BaseStudioRender

/// Manual regression gate: replay an existing recording without screen capture or UI.
/// Set BS_EXISTING_BUNDLE to a .basestudio directory; normal test runs skip it.
final class ExistingBundleExportProbeTests: XCTestCase {
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    func testReplayRetainedBundleWithinMemoryLimit() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else {
            throw XCTSkip("Set BS_EXISTING_BUNDLE for the local replay")
        }
        let bundle = ProjectBundle(url: URL(fileURLWithPath: path, isDirectory: true))
        let project = try ProjectIO.load(from: bundle)
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("base-studio-export-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let limitMB = 1_500
        let sampler = Task.detached { () -> Int in
            var peak = 0
            while !Task.isCancelled {
                let value = Self.footprintMB()
                guard value >= 0 else {
                    fputs("EXPORT-PROBE abort: footprint unavailable\n", stderr)
                    exit(3)
                }
                peak = max(peak, value)
                if value > limitMB {
                    fputs("EXPORT-PROBE abort: footprint \(value) MB > \(limitMB) MB\n", stderr)
                    exit(3)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return peak
        }
        defer { sampler.cancel() }

        let output = try await ExportPipeline().run(.init(
            project: project,
            bundleURL: bundle.url,
            outputURL: outputDir.appendingPathComponent("replayed.mp4"),
            fps: 60,
            bitrate: 8_000_000,
            audioMode: .both
        ))
        sampler.cancel()
        let peak = await sampler.value
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        print("EXPORT-PROBE peak=\(peak) MB duration=\(duration) s videoTracks=\(tracks.count)")
        XCTAssertLessThan(peak, limitMB)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(duration, project.timelineDuration.seconds, accuracy: 3)
    }
}
