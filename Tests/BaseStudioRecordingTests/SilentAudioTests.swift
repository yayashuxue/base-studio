import AVFoundation
import XCTest
@testable import BaseStudioRecording

/// Paused audio is written as silence so the file keeps its timeline.
/// Dropping buffers instead let AVAssetWriter pack later sound earlier
/// (live test 11/10: sound 10 s ahead of picture after a 10 s pause).
final class SilentAudioTests: XCTestCase {
    private let rate = 48_000.0

    private func pcm(at t: Double, frames: Int, value: Float) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 4, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: frames * 4,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var samples = [Float](repeating: value, count: frames)
        CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 4)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!,
            sampleCount: frames, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    func testCopyIsSilentWithSameTiming() throws {
        let src = pcm(at: 12.5, frames: 1024, value: 0.7)
        let s = try XCTUnwrap(SilentAudio.copy(of: src))
        XCTAssertEqual(CMSampleBufferGetNumSamples(s), 1024)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(s).seconds, 12.5, accuracy: 1e-9)
        XCTAssertEqual(CMSampleBufferGetDuration(s).seconds, CMSampleBufferGetDuration(src).seconds, accuracy: 1e-9)
        let bb = try XCTUnwrap(CMSampleBufferGetDataBuffer(s))
        var out = [Float](repeating: 1, count: 1024)
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: 4096, destination: &out)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    /// 1 s sound, 1 s "paused", 1 s sound → a 3 s file whose second sound
    /// starts at 2 s. With the paused buffers dropped it would start at 1 s.
    func testSilenceKeepsTheTimelineInAnAACFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-silent-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let n = 1024
        var t = 0.0
        while t < 3 - 1e-9 {
            var sb = pcm(at: t, frames: n, value: 0.5)
            if t >= 1 && t < 2 { sb = SilentAudio.copy(of: sb)! }     // paused second
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(input.append(sb))
            t += Double(n) / rate
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.1)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.startReading()
        var pcmAll: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var f = [Float](repeating: 0, count: len / 4)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &f)
            pcmAll += f
        }
        func level(_ a: Double, _ b: Double) -> Float {
            let s = Int(a * rate), e = min(pcmAll.count, Int(b * rate))
            return pcmAll[s..<e].map(abs).max() ?? 0
        }
        XCTAssertGreaterThan(level(0.2, 0.8), 0.2, "first second has sound")
        XCTAssertLessThan(level(1.2, 1.8), 0.01, "paused second is silent")
        XCTAssertGreaterThan(level(2.2, 2.8), 0.2, "sound after the pause stays at 2 s")
    }
}
