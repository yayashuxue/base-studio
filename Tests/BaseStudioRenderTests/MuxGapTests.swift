import AVFoundation
import XCTest
@testable import BaseStudioRender

/// The final mux must finish when the picture has a long gap and the sound
/// does not — exactly what a recovered take produces. The live 330 s take
/// (52 s picture gap) stalled the earliest-first mux for 20 s and failed.
final class MuxGapTests: XCTestCase {

    static let ffmpeg: String? = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func testMuxFinishesAcrossALongVideoGap() async throws {
        guard let ffmpeg = Self.ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mux-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Video: 45 s source with frames only in 0–5 s and 40–45 s (35 s gap).
        let video = dir.appendingPathComponent("v.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=45",
                       "-vf", "select='lt(t\\,5)+gte(t\\,40)'", "-fps_mode", "vfr",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "30", video.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        // Audio: continuous 45 s AAC from AVAssetWriter (carries iTunSMPB, as
        // the export's audio pass does).
        let audio = dir.appendingPathComponent("a.m4a")
        try await writeSine(to: audio, seconds: 45)

        let out = dir.appendingPathComponent("out.mp4")
        let start = Date()
        try await ExportPipeline.mux(video: video, audio: audio, into: out)
        let took = Date().timeIntervalSince(start)
        let asset = AVURLAsset(url: out)
        let dur = try await asset.load(.duration).seconds
        let a = try await asset.loadTracks(withMediaType: .audio).first
        let aDur = try await a?.load(.timeRange).duration.seconds ?? 0
        print("MUX-GAP took=\(took)s duration=\(dur) audio=\(aDur)")
        XCTAssertLessThan(took, 15, "mux took \(took) s")
        XCTAssertEqual(dur, 45, accuracy: 0.5, "output must cover the whole take")
        XCTAssertGreaterThan(aDur, 40, "audio across the video gap must survive (\(aDur) s)")
    }

    private func writeSine(to url: URL, seconds: Double) async throws {
        let rate = 48_000.0
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
            AVSampleRateKey: rate, AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let total = Int(seconds * rate)
        var produced = 0
        while produced < total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let n = min(1024, total - produced)
            var samples = [Int16](repeating: 0, count: n * 2)
            for i in 0..<n {
                let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(produced + i) / rate))
                samples[2 * i] = v; samples[2 * i + 1] = v
            }
            let bytes = samples.count * 2
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                               blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                               dataLength: bytes, flags: 0, blockBufferOut: &bb)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: bb!, formatDescription: fmt!, sampleCount: n,
                presentationTimeStamp: CMTime(value: CMTimeValue(produced), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &sb)
            input.append(sb!)
            produced += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
