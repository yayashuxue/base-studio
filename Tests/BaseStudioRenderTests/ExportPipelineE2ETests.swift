import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import BaseStudioCore
@testable import BaseStudioRender

/// Headless end-to-end test for `ExportPipeline`. Synthesizes a minimal
/// `.basestudio` bundle (silent screen.mov + sine-wave mic.m4a + metadata.json)
/// where every host-clock anchor is **non-zero** — exactly the condition that
/// regressed audio-out before the file-time fix shipped in `89b53ee`.
///
/// What this guards (RCA-grade):
///   * `AVAssetWriter.startSession(atSourceTime:)` shifts each on-disk track to
///     start at file-time 0. Pre-fix code seeked these tracks with host-clock
///     PTSes → seeks landed past EOF → output mp4 had a video track only and
///     a silent (or missing) audio track.
///   * Today the export pipeline routes both video seeks and audio mixer
///     `originPTS` through `SourceClip.fileTime(at:)`. This test fails fast if
///     anyone reverts that contract.
@available(macOS 13.0, *)
final class ExportPipelineE2ETests: XCTestCase {

    /// Pick a host-clock anchor that is clearly not file-time 0. Any non-zero
    /// number works; using a realistic-looking value keeps debug output legible.
    private let hostFirstPTS = CMTime(value: 1_234_567_890, timescale: 600)
    private let durationSec = 2.0
    private let videoFPS: Int32 = 30
    private let videoW = 640
    private let videoH = 360
    private let audioSampleRate: Double = 48_000

    override func setUp() {
        super.setUp()
        // Hard wall-clock cap so a regression hangs in CI/dev for at most 60s
        // instead of occupying xctest indefinitely. This test does real
        // AVAssetWriter encoding + AudioMixer mixing and finishes in <10s on
        // an M-series Mac, so 60s is a generous ceiling.
        executionTimeAllowance = 60
    }

    func testExportProducesAudibleAudioTrackWithNonZeroFirstPTS() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "bs-e2e-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let bundleURL = tmp.appendingPathComponent("recording.basestudio", isDirectory: true)
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let screenURL = bundleURL.appendingPathComponent("screen.mov")
        let micURL = bundleURL.appendingPathComponent("mic.m4a")
        let metadataURL = bundleURL.appendingPathComponent("metadata.json")
        let outURL = tmp.appendingPathComponent("out.mp4")

        try await writeSilentScreenMov(to: screenURL)
        try await writeSineMicM4A(to: micURL)
        try writeMetadata(to: metadataURL)

        let project = makeProject()

        let pipeline = ExportPipeline()
        let result = try await pipeline.run(.init(
            project: project,
            bundleURL: bundleURL,
            outputURL: outURL,
            fps: Int(videoFPS),
            bitrate: 4_000_000,
            audioMode: .both
        ))

        XCTAssertTrue(fm.fileExists(atPath: result.path), "no output file")

        // Re-open and assert the output really has both tracks + audible audio.
        let asset = AVURLAsset(url: result)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1, "expected exactly one video track")
        XCTAssertEqual(audioTracks.count, 1, "expected exactly one audio track")

        let audioTrack = try XCTUnwrap(audioTracks.first)
        let assetDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(assetDuration, durationSec, accuracy: 0.2)

        // Reading actual sample buffers is the only way to prove the audio is
        // not just an empty track header. Pre-fix exports produced a writer
        // input with .markAsFinished() called but no buffers appended.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: audioSampleRate,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var totalFrames = 0
        var peakAbs: Int16 = 0
        while let buf = output.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(buf)
            totalFrames += n
            if let bb = CMSampleBufferGetDataBuffer(buf) {
                var len = 0
                var ptr: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                                totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
                   let raw = ptr {
                    raw.withMemoryRebound(to: Int16.self, capacity: len / 2) { p in
                        let count = len / 2
                        for i in 0..<count {
                            let v = abs(Int(p[i]))
                            if v > Int(peakAbs) { peakAbs = Int16(min(v, 32_767)) }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(reader.status, .completed,
                       "reader stopped with \(reader.error?.localizedDescription ?? "?")")

        let audibleSeconds = Double(totalFrames) / audioSampleRate
        XCTAssertGreaterThan(audibleSeconds, durationSec * 0.8,
                             "audio track too short: \(audibleSeconds)s of \(durationSec)s expected")
        XCTAssertGreaterThan(peakAbs, 1_000,
                             "audio track present but silent (peak \(peakAbs)) — file-time fix likely regressed")
    }

    // MARK: - fixture builders

    private func makeProject() -> Project {
        // Single source, no sidecars. file-time 0..duration on disk; host-clock
        // anchor at hostFirstPTS — exactly the (non-zero anchor) shape every
        // real recording has.
        let firstPTS = TimePoint(hostFirstPTS)
        let lastPTS = TimePoint(CMTimeAdd(hostFirstPTS, CMTime(seconds: durationSec, preferredTimescale: 600)))
        let screen = SourceClip(
            id: SourceID.screen,
            relativeMediaPath: "screen.mov",
            widthPx: videoW, heightPx: videoH,
            firstPTS: firstPTS,
            sidecars: []
        )
        // Trim window covers the whole clip in host-clock coords.
        let segment = VideoSegment(
            sourceID: SourceID.screen,
            sourceIn: firstPTS,
            sourceOut: lastPTS,
            timelineIn: TimePoint(.zero)
        )
        // Background-only graph keeps the per-frame work tiny without
        // skipping the compose path that touches our canvas size.
        let bg = NodeInstance(
            instanceID: "bg_1",
            nodeType: BackgroundCompose.spec.id,
            bindings: [:],
            enabled: true
        )
        return Project(
            sources: [screen],
            videoTrack: VideoTrack(segments: [segment]),
            nodeGraph: NodeGraph(nodes: [bg]),
            canvas: CanvasSpec(widthPx: 1280, heightPx: 720),
            timelineDuration: TimePoint(CMTime(seconds: durationSec, preferredTimescale: 600))
        )
    }

    private func writeMetadata(to url: URL) throws {
        let firstPTS = TimePoint(hostFirstPTS)
        let lastPTS = TimePoint(CMTimeAdd(hostFirstPTS, CMTime(seconds: durationSec, preferredTimescale: 600)))
        let meta = RecordingMetadata(
            displayID: 1,
            widthPx: videoW, heightPx: videoH,
            pointScale: 2.0,
            displayOriginXPt: 0, displayOriginYPt: 0,
            displayWidthPt: Double(videoW) / 2.0,
            displayHeightPt: Double(videoH) / 2.0,
            firstVideoPTS: firstPTS,
            lastVideoPTS: lastPTS,
            sources: [
                SourceID.screen: SourceMediaInfo(
                    firstVideoPTS: firstPTS, lastVideoPTS: lastPTS,
                    widthPx: videoW, heightPx: videoH
                ),
            ],
            // Mic shares the screen's host anchor — same shape as the modern
            // recorder pipeline writes when both start in lockstep.
            micFirstPTS: firstPTS
        )
        let data = try JSONEncoder().encode(meta)
        try data.write(to: url)
    }

    /// Writes a silent H.264 mov whose track is shifted to file-time 0 (matches
    /// what `ScreenRecorder` produces). Solid blue frames; content doesn't matter.
    private func writeSilentScreenMov(to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoW,
            AVVideoHeightKey: videoH,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoW,
                kCVPixelBufferHeightKey as String: videoH,
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(durationSec * Double(videoFPS))
        let pool = adaptor.pixelBufferPool!
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                memset(base, 0x40, CVPixelBufferGetDataSize(buf))   // mid-blue-ish
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let pts = CMTime(value: CMTimeValue(i), timescale: videoFPS)
            adaptor.append(buf, withPresentationTime: pts)
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed,
                       "writer error \(writer.error?.localizedDescription ?? "?")")
    }

    /// Writes a 440Hz sine wave to mic.m4a. Like `screen.mov`, the track is
    /// shifted to file-time 0 — `MicRecorder` does the same.
    private func writeSineMicM4A(to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: audioSampleRate,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Build CMSampleBuffers of int16 stereo PCM, 1024 samples per buffer.
        let chunkFrames = 1024
        let totalFrames = Int(durationSec * audioSampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        let s = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &fmt
        )
        XCTAssertEqual(s, noErr)

        var produced = 0
        while produced < totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let n = min(chunkFrames, totalFrames - produced)
            var samples = [Int16](repeating: 0, count: n * 2)
            let twoPi = 2.0 * Double.pi
            let freq = 440.0
            for i in 0..<n {
                let t = Double(produced + i) / audioSampleRate
                let v = Int16(Double(Int16.max) * 0.5 * sin(twoPi * freq * t))
                samples[i * 2] = v
                samples[i * 2 + 1] = v
            }
            let byteCount = samples.count * MemoryLayout<Int16>.size
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: byteCount, flags: 0, blockBufferOut: &bb
            )
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb!,
                                                  offsetIntoDestination: 0, dataLength: byteCount)
            }
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(audioSampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(produced),
                                              timescale: CMTimeScale(audioSampleRate)),
                decodeTimeStamp: .invalid
            )
            var sampleSize = MemoryLayout<Int16>.size * 2
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: bb,
                dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: fmt, sampleCount: n,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            input.append(sampleBuffer!)
            produced += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed,
                       "mic writer error \(writer.error?.localizedDescription ?? "?")")
    }
}
