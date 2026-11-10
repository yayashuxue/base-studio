import AVFoundation
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRender

/// The editor had no audio at all. Preview audio must put each source's
/// sound where export puts it: same origins, same TimeMap.
final class PreviewAudioTests: XCTestCase {
    private var dir: URL!
    private let rate = 48_000.0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-prevaudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSourcesLandAtTheirOrigins() async throws {
        // System audio: click at file 2.0 s, timeline-zero at file 0.5 s → 1.5 s.
        // Mic: started 0.3 s after timeline-zero (origin -0.3), click at file 1.0 s → 1.3 s.
        let sys = try writeClicks(at: [2.0], seconds: 4, name: "sys.wav")
        let mic = try writeClicks(at: [1.0], seconds: 3, name: "mic.wav")
        let map = TimeMap.identity(trimInSec: 0, trimOutSec: 3)

        let a = try await clicks(in: [.init(url: sys, originPTS: secs(0.5), gain: 1)], map: map)
        let b = try await clicks(in: [.init(url: mic, originPTS: secs(-0.3), gain: 1)], map: map)
        XCTAssertEqual(a.count, 1); XCTAssertEqual(a.first ?? -1, 1.5, accuracy: 0.01)
        XCTAssertEqual(b.count, 1); XCTAssertEqual(b.first ?? -1, 1.3, accuracy: 0.01)
    }

    func testSpeedRegionScalesTimeline() async throws {
        // 2× over source 0–1 s: a click at source 1.5 s plays at 0.5 + 0.5 = 1.0 s,
        // one at source 0.8 s plays at 0.4 s.
        let src = try writeClicks(at: [0.8, 1.5], seconds: 3, name: "speed.wav")
        let map = TimeMap.make(trimInSec: 0, trimOutSec: 3, speedRegions: [(0, 1, 2)])
        XCTAssertEqual(map.timelineDurationSec, 2.5, accuracy: 1e-9)
        let got = try await clicks(in: [.init(url: src, originPTS: .zero, gain: 1)], map: map)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.first ?? -1, 0.4, accuracy: 0.02)
        XCTAssertEqual(got.last ?? -1, 1.0, accuracy: 0.02)
    }

    // MARK: - helpers

    private func secs(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48_000) }

    /// Mono 48 kHz file, silent except 5 ms full-scale bursts at `at`.
    private func writeClicks(at: [Double], seconds: Double, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        let p = buf.floatChannelData![0]
        for i in 0..<Int(n) { p[i] = 0 }
        for t in at { for i in Int(t * rate)..<min(Int(n), Int(t * rate) + 240) { p[i] = 0.9 } }
        try file.write(from: buf)
        return url
    }

    /// Times of click onsets in the built preview audio (as the player hears it).
    private func clicks(in sources: [AudioMixer.Source], map: TimeMap) async throws -> [Double] {
        let built = try await PreviewAudio.build(sources: sources, timeMap: map)
        let b = try XCTUnwrap(built)
        let reader = try AVAssetReader(asset: b.composition)
        let tracks = try await b.composition.loadTracks(withMediaType: .audio)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        out.audioMix = b.audioMix
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: len / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            samples += chunk
        }
        var onsets: [Double] = []
        var last = -1.0
        for (i, v) in samples.enumerated() where abs(v) > 0.3 {
            let t = Double(i) / rate
            if t - last > 0.1 { onsets.append(t) }
            last = t
        }
        return onsets
    }
}
