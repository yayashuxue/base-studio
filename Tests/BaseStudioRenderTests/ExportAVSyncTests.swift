import AVFoundation
import BaseStudioCore
import XCTest
@testable import BaseStudioRender

/// Export must not shift audio against picture. Fixture: a screen.mov whose
/// whole frame flashes white and whose system audio clicks at exactly 1, 2
/// and 3 s. After export, every flash/click pair must still coincide.
/// (A live MacBook measurement read export audio ~50 ms late — that was
/// ffmpeg ignoring the AAC priming trim; Apple decoding is in sync.)
/// Fixture + measurement use ffmpeg; skipped where it isn't installed.
final class ExportAVSyncTests: XCTestCase {

    static let ffmpeg: String? = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private let hostFirstPTS = CMTime(value: 1_234_567_890, timescale: 600)
    private let durationSec = 4.0
    private let w = 640, h = 360

    func testExportKeepsFlashAndClickTogether() async throws {
        guard let ffmpeg = Self.ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bs-sync-\(UUID().uuidString)", isDirectory: true)
        let bundle = tmp.appendingPathComponent("rec.basestudio", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["BS_KEEP_EXPORT_TEMPS"] == nil { try? fm.removeItem(at: tmp) } else { print("KEPT \(tmp.path)") } }

        // Source: 30 fps H.264 + AAC; flash and 20 ms 1 kHz click at 1/2/3 s.
        try run(ffmpeg, ["-v", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=\(w)x\(h):r=30:d=\(durationSec)",
            "-f", "lavfi", "-i", "aevalsrc='0.8*sin(2*PI*1000*t)*lt(mod(t\\,1)\\,0.02)*gte(t\\,0.5)':s=48000:d=\(durationSec)",
            "-vf", "drawbox=c=white:t=fill:enable='lt(mod(t\\,1)\\,0.067)*gte(t\\,0.5)'",
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "30",
            "-c:a", "aac", "-ac", "2", bundle.appendingPathComponent("screen.mov").path])
        let srcOffsets = try await offsets(ffmpeg, bundle.appendingPathComponent("screen.mov"), appleAudio: true)
        XCTAssertEqual(srcOffsets.count, 3, "fixture should have 3 flash/click pairs: \(srcOffsets)")
        for o in srcOffsets { XCTAssertEqual(o, 0, accuracy: 15, "fixture itself out of sync: \(srcOffsets)") }

        try writeMetadata(bundle.appendingPathComponent("metadata.json"))
        let out = tmp.appendingPathComponent("out.mp4")
        _ = try await ExportPipeline().run(.init(
            project: makeProject(), bundleURL: bundle, outputURL: out,
            fps: 30, bitrate: 4_000_000, audioMode: .systemOnly))

        // Both decoders must agree: Apple (QuickTime) and ffmpeg (what most
        // upload pipelines use). The ffmpeg side was 44 ms late until the AAC
        // priming tag was carried into the mp4.
        for (name, useApple) in [("Apple", true), ("ffmpeg", false)] {
            let o = try await offsets(ffmpeg, out, appleAudio: useApple)
            XCTAssertEqual(o.count, 3, "\(name): export lost flash/click pairs: \(o)")
            for x in o { XCTAssertEqual(x, 0, accuracy: 15, "\(name): audio off by \(x) ms after export (all: \(o))") }
        }
    }

    // MARK: - measurement

    /// Click onset minus flash onset (ms) for each pair.
    private func offsets(_ ffmpeg: String, _ url: URL, appleAudio: Bool) async throws -> [Double] {
        // Flash onsets: per-frame mean luma, rising edge over 128.
        let v = try run(ffmpeg, ["-v", "info", "-i", url.path, "-map", "0:v",
                                 "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
                                 "-f", "null", "-"], captureStderr: true)
        var flashes: [Double] = []
        var t: Double?; var prev = 0.0
        for line in v.split(separator: "\n") {
            if let r = line.range(of: "pts_time:") { t = Double(line[r.upperBound...].split(separator: " ").first ?? "") }
            if let r = line.range(of: "YAVG="), let y = Double(line[r.upperBound...]), let tt = t {
                if y > 128 && prev <= 128 { flashes.append(tt) }
                prev = y
            }
        }
        // Click onsets, decoded by AVFoundation (what QuickTime / Apple
        // players use; it honours the AAC priming trim). ffmpeg does not honour
        // the trim AVAssetWriter writes into the exported .mp4 and reads the
        // audio 44 ms late — see the note in ExportPipeline.mux.
        let samples: [Float]
        if appleAudio {
            samples = try await decodeMonoPCM(url)
        } else {
            let pcm = try runData(ffmpeg, ["-v", "error", "-i", url.path, "-map", "0:a", "-ac", "1",
                                           "-ar", "48000", "-f", "f32le", "-"])
            samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        var clicks: [Double] = []; var last = -9.0
        var i = 0
        while i + 48 <= samples.count {
            let peak = samples[i..<(i + 48)].map(abs).max() ?? 0
            let ts = Double(i) / 48_000
            if peak > 0.1 && ts - last > 0.5 { clicks.append(ts); last = ts }
            i += 48
        }
        return flashes.compactMap { f in
            clicks.min(by: { abs($0 - f) < abs($1 - f) }).flatMap { abs($0 - f) < 0.5 ? ($0 - f) * 1000 : nil }
        }
    }

    private func decodeMonoPCM(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var p: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p)
            if let p { p.withMemoryRebound(to: Float.self, capacity: len / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: len / 4)) } }
        }
        return samples
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String], captureStderr: Bool = false) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe()
        if captureStderr { p.standardError = pipe } else { p.standardOutput = FileHandle.nullDevice }
        try p.run()
        let data = captureStderr ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "ffmpeg \(args.prefix(6)) failed")
        return String(decoding: data, as: UTF8.self)
    }

    private func runData(_ exe: String, _ args: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    // MARK: - fixture (same shape as ExportPipelineE2ETests)

    private func makeProject() -> Project {
        let firstPTS = TimePoint(hostFirstPTS)
        let lastPTS = TimePoint(CMTimeAdd(hostFirstPTS, CMTime(seconds: durationSec, preferredTimescale: 600)))
        let screen = SourceClip(id: SourceID.screen, relativeMediaPath: "screen.mov",
                                widthPx: w, heightPx: h, firstPTS: firstPTS, sidecars: [])
        let segment = VideoSegment(sourceID: SourceID.screen, sourceIn: firstPTS, sourceOut: lastPTS,
                                   timelineIn: TimePoint(.zero))
        let bg = NodeInstance(instanceID: "bg_1", nodeType: BackgroundCompose.spec.id, bindings: [:], enabled: true)
        return Project(sources: [screen], videoTrack: VideoTrack(segments: [segment]),
                       nodeGraph: NodeGraph(nodes: [bg]), canvas: CanvasSpec(widthPx: 1280, heightPx: 720),
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
