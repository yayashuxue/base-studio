import AVFoundation
import Accelerate
import BaseStudioCore
import CoreMedia
import Foundation

/// Offline 2-source PCM mixer: reads two audio assets, decodes to 32-bit float
/// stereo at 48 kHz, sums sample-for-sample (with optional per-source gain),
/// retimes PTSes to a target timeline, and feeds AAC-encoded sample buffers into
/// an AVAssetWriterInput.
///
/// When speed-bearing zoom regions exist, callers pass `timeMap` so audio is
/// time-mapped to match the video. The current implementation uses linear-rate
/// resampling per segment (v1 — pitch shifts at non-1× speeds; pitch-preserving
/// stretch via `AVAudioUnitTimePitch` is the planned upgrade).
public enum AudioMixer {

    public struct Source {
        public let url: URL
        public let originPTS: CMTime    // host-clock anchor; subtracted from sample PTS to land on timeline-zero
        public let gain: Float          // 0..1
        public init(url: URL, originPTS: CMTime, gain: Float = 1.0) {
            self.url = url
            self.originPTS = originPTS
            self.gain = gain
        }
    }

    public enum Error: Swift.Error {
        case readerSetup(String)
        case unsupported
    }

    /// Decode each source to PCM, optionally apply a time-map (speed remap),
    /// mix sample-for-sample, append AAC-encoded chunks to `audioInput`.
    ///
    /// When `timeMap` has any segment with speed != 1.0, audio uses linear-rate
    /// resampling that follows the video time map exactly. Without that, callers
    /// can pass `nil` for the fast pass-through path.
    public static func mix(
        _ sources: [Source],
        timelineDuration: CMTime,
        timeMap: TimeMap? = nil,
        into audioInput: AVAssetWriterInput,
        canceled: @escaping () -> Bool = { false }
    ) async throws {
        if let map = timeMap, map.segments.contains(where: { abs($0.speed - 1.0) > 0.001 }) {
            try await mixWithTimeMap(
                sources, timeMap: map,
                timelineDuration: timelineDuration,
                into: audioInput, canceled: canceled
            )
            return
        }
        try await mixPassthrough(
            sources, timelineDuration: timelineDuration,
            into: audioInput, canceled: canceled
        )
    }

    private static func mixPassthrough(
        _ sources: [Source],
        timelineDuration: CMTime,
        into audioInput: AVAssetWriterInput,
        canceled: @escaping () -> Bool = { false }
    ) async throws {
        let sampleRate: Double = 48_000
        let channelCount: Int = 2

        // Open readers, configured to deliver 32-bit float interleaved PCM @ 48k stereo.
        var readers: [(AVAssetReader, AVAssetReaderTrackOutput, Source)] = []
        for src in sources {
            let asset = AVURLAsset(url: src.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { continue }
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw Error.readerSetup("cannot add output for \(src.url.lastPathComponent)")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw Error.readerSetup(reader.error?.localizedDescription ?? "?")
            }
            readers.append((reader, output, src))
        }
        guard !readers.isEmpty else { return }

        // Walk a sliding playhead in samples; for each chunk, read each source's
        // contribution at that time and accumulate. Simpler approach for v1:
        // pull one sample buffer at a time from each source, sum into a working
        // ring keyed by absolute sample index, flush full chunks to the writer.
        let chunkFrames = 1024
        let bytesPerSample = 4
        let bytesPerFrame = bytesPerSample * channelCount

        // We accumulate into a Float buffer keyed by sample index (timeline samples).
        // For long mixes this could grow unbounded; we flush in chunks once the
        // earliest source has produced enough.
        var mix: [Int: [Float]] = [:]   // chunk index → [chunkFrames * channels] floats
        var nextChunkToWrite: Int = 0
        let totalTimelineSamples = Int(timelineDuration.seconds * sampleRate)

        // Per-source running cursor (next absolute sample index to write).
        var doneCount = 0
        let total = readers.count

        // Drive each source until it's drained.
        var sourceStates = readers.map { _ in (samplesEmitted: 0, drained: false) }

        while doneCount < total {
            if canceled() { return }
            for i in 0..<readers.count where !sourceStates[i].drained {
                let (reader, output, src) = readers[i]
                guard reader.status == .reading,
                      let sb = output.copyNextSampleBuffer() else {
                    sourceStates[i].drained = true
                    doneCount += 1
                    continue
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let timelinePTS = CMTimeSubtract(pts, src.originPTS)
                let frameCount = CMSampleBufferGetNumSamples(sb)
                guard frameCount > 0,
                      let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { continue }
                var lengthAtOffset = 0
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>? = nil
                CMBlockBufferGetDataPointer(
                    blockBuffer, atOffset: 0,
                    lengthAtOffsetOut: &lengthAtOffset,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )
                guard let dataPointer = dataPointer else { continue }

                let samples = dataPointer.withMemoryRebound(to: Float.self, capacity: frameCount * channelCount) { ptr in
                    UnsafeBufferPointer(start: ptr, count: frameCount * channelCount)
                }

                // Where these samples land on the timeline (in absolute sample index).
                let timelineFirstSample = Int(round(timelinePTS.seconds * sampleRate))
                if timelineFirstSample + frameCount < 0 { continue }
                if timelineFirstSample >= totalTimelineSamples {
                    sourceStates[i].drained = true
                    doneCount += 1
                    continue
                }

                let startSample = max(0, timelineFirstSample)
                let endSample = min(totalTimelineSamples, timelineFirstSample + frameCount)
                let srcStart = startSample - timelineFirstSample
                let srcEnd = srcStart + (endSample - startSample)

                let gain = src.gain
                for n in srcStart..<srcEnd {
                    let absSample = (timelineFirstSample + n)
                    let chunkIdx = absSample / chunkFrames
                    let local = (absSample % chunkFrames) * channelCount
                    if mix[chunkIdx] == nil {
                        mix[chunkIdx] = Array(repeating: 0, count: chunkFrames * channelCount)
                    }
                    let frameOff = n * channelCount
                    mix[chunkIdx]![local + 0] += samples[frameOff + 0] * gain
                    if channelCount > 1 {
                        mix[chunkIdx]![local + 1] += samples[frameOff + 1] * gain
                    }
                }

                sourceStates[i].samplesEmitted = max(sourceStates[i].samplesEmitted, endSample)
            }

            // Flush chunks up to the *minimum* progress across non-drained sources
            // (safe to write — no source can still contribute to those chunks).
            let safeUpTo = sourceStates.enumerated().reduce(Int.max) { (acc, it) in
                let (_, st) = it
                return st.drained ? acc : min(acc, st.samplesEmitted)
            }
            let safeChunk = (safeUpTo == Int.max ? totalTimelineSamples : safeUpTo) / chunkFrames
            try await flushChunks(
                upTo: safeChunk, mix: &mix, nextChunkToWrite: &nextChunkToWrite,
                channelCount: channelCount, sampleRate: sampleRate,
                chunkFrames: chunkFrames, bytesPerFrame: bytesPerFrame,
                audioInput: audioInput
            )
        }

        // Final flush.
        let lastChunk = (totalTimelineSamples + chunkFrames - 1) / chunkFrames
        try await flushChunks(
            upTo: lastChunk, mix: &mix, nextChunkToWrite: &nextChunkToWrite,
            channelCount: channelCount, sampleRate: sampleRate,
            chunkFrames: chunkFrames, bytesPerFrame: bytesPerFrame,
            audioInput: audioInput
        )
    }

    private static func flushChunks(
        upTo lastChunkExclusive: Int,
        mix: inout [Int: [Float]],
        nextChunkToWrite: inout Int,
        channelCount: Int, sampleRate: Double, chunkFrames: Int, bytesPerFrame: Int,
        audioInput: AVAssetWriterInput
    ) async throws {
        while nextChunkToWrite < lastChunkExclusive {
            let chunk = mix.removeValue(forKey: nextChunkToWrite)
                ?? Array(repeating: 0, count: chunkFrames * channelCount)

            // Soft-clamp to avoid >1 from sums.
            var clamped = chunk
            var minVal: Float = -1.0
            var maxVal: Float = 1.0
            vDSP_vclip(clamped, 1, &minVal, &maxVal, &clamped, 1, vDSP_Length(clamped.count))

            // Wait for the writer to be ready.
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            guard let sb = makePCMSampleBuffer(
                samples: clamped,
                frameCount: chunkFrames,
                channelCount: channelCount,
                sampleRate: sampleRate,
                pts: CMTime(value: CMTimeValue(nextChunkToWrite * chunkFrames),
                            timescale: CMTimeScale(sampleRate))
            ) else {
                nextChunkToWrite += 1
                continue
            }
            audioInput.append(sb)
            nextChunkToWrite += 1
        }
    }

    // MARK: - speed-remap path

    /// For each TimeMap segment: read source PCM in [sourceStart..sourceEnd] for
    /// each source, resample to (timelineDur * sampleRate) frames via linear
    /// interpolation (chipmunk for v1), sum sources, append to writer.
    private static func mixWithTimeMap(
        _ sources: [Source], timeMap: TimeMap,
        timelineDuration: CMTime,
        into audioInput: AVAssetWriterInput,
        canceled: @escaping () -> Bool
    ) async throws {
        let sampleRate: Double = 48_000
        let channelCount = 2
        var timelineCursorSamples = 0

        for tlSeg in timeMap.timelineSegments() {
            if canceled() { return }
            let outFrames = max(1, Int((tlSeg.timelineEnd - tlSeg.timelineStart) * sampleRate))
            var mix = [Float](repeating: 0, count: outFrames * channelCount)

            for src in sources {
                let srcStart = src.originPTS.seconds + timeMap.trimInSec + tlSeg.sourceStart
                let srcEnd = src.originPTS.seconds + timeMap.trimInSec + tlSeg.sourceEnd
                let pcm = try await readPCM(
                    url: src.url,
                    sourceStartSec: srcStart, sourceEndSec: srcEnd,
                    sampleRate: sampleRate, channelCount: channelCount
                )
                // Pitch-preserving stretch when speed != 1.0; otherwise pass-through.
                let stretched: [Float]
                if abs(tlSeg.speed - 1.0) > 0.001 {
                    stretched = (try? await stretchPitchPreserving(
                        pcm: pcm, channels: channelCount, sampleRate: sampleRate,
                        rate: Float(tlSeg.speed), targetFrames: outFrames
                    )) ?? linearResample(pcm: pcm, channels: channelCount, targetFrames: outFrames)
                } else {
                    stretched = pcm   // identity
                }
                accumulate(
                    src: stretched, srcChannels: channelCount,
                    into: &mix, outFrames: outFrames, outChannels: channelCount,
                    gain: src.gain
                )
            }

            // Soft-clamp.
            var minVal: Float = -1.0, maxVal: Float = 1.0
            vDSP_vclip(mix, 1, &minVal, &maxVal, &mix, 1, vDSP_Length(mix.count))

            // Emit in 1024-sample chunks so the encoder doesn't choke on huge buffers.
            let chunk = 1024
            var off = 0
            while off < outFrames {
                if canceled() { return }
                let n = min(chunk, outFrames - off)
                while !audioInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let absSample = timelineCursorSamples + off
                let pts = CMTime(value: CMTimeValue(absSample), timescale: CMTimeScale(sampleRate))
                let slice = Array(mix[off * channelCount..<(off + n) * channelCount])
                if let sb = makePCMSampleBuffer(
                    samples: slice, frameCount: n,
                    channelCount: channelCount, sampleRate: sampleRate, pts: pts
                ) {
                    audioInput.append(sb)
                }
                off += n
            }
            timelineCursorSamples += outFrames
        }
    }

    /// Read source audio in `[sourceStartSec, sourceEndSec]` decoded as 32-bit float
    /// interleaved at the requested sample rate / channel count.
    private static func readPCM(
        url: URL, sourceStartSec: Double, sourceEndSec: Double,
        sampleRate: Double, channelCount: Int
    ) async throws -> [Float] {
        guard sourceEndSec > sourceStartSec else { return [] }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: sourceStartSec, preferredTimescale: 600),
            end: CMTime(seconds: sourceEndSec, preferredTimescale: 600)
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var pcm: [Float] = []
        while let sb = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sb)
            guard frames > 0,
                  let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var totalLen = 0
            var dataPtr: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(
                block, atOffset: 0,
                lengthAtOffsetOut: nil, totalLengthOut: &totalLen,
                dataPointerOut: &dataPtr
            )
            guard let dataPtr else { continue }
            dataPtr.withMemoryRebound(to: Float.self, capacity: frames * channelCount) { ptr in
                pcm.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames * channelCount))
            }
        }
        return pcm
    }

    /// Linear-interp resample to a fixed length, returning a new buffer (used as
    /// a fallback when AVAudioUnitTimePitch isn't available).
    private static func linearResample(
        pcm: [Float], channels: Int, targetFrames: Int
    ) -> [Float] {
        guard !pcm.isEmpty, targetFrames > 0 else { return [] }
        let srcFrames = pcm.count / channels
        if srcFrames == 0 { return [] }
        if srcFrames == targetFrames { return pcm }
        var out = [Float](repeating: 0, count: targetFrames * channels)
        let ratio = Double(srcFrames - 1) / Double(max(1, targetFrames - 1))
        for i in 0..<targetFrames {
            let s = Double(i) * ratio
            let i0 = Int(s)
            let i1 = min(srcFrames - 1, i0 + 1)
            let a = Float(s - Double(i0))
            for c in 0..<channels {
                let v0 = pcm[i0 * channels + c]
                let v1 = pcm[i1 * channels + c]
                out[i * channels + c] = v0 + (v1 - v0) * a
            }
        }
        return out
    }

    /// Pitch-preserving time stretch via AVAudioEngine offline rendering through
    /// an `AVAudioUnitTimePitch` node. `rate > 1` shortens the output; `rate < 1`
    /// lengthens it. Output is trimmed/padded to exactly `targetFrames`.
    private static func stretchPitchPreserving(
        pcm: [Float], channels: Int, sampleRate: Double,
        rate: Float, targetFrames: Int
    ) async throws -> [Float] {
        guard !pcm.isEmpty, targetFrames > 0 else { return [] }
        let srcFrames = pcm.count / channels
        guard srcFrames > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: sampleRate,
                  channels: AVAudioChannelCount(channels)
              ),
              let inBuf = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(srcFrames)
              ),
              let chans = inBuf.floatChannelData
        else { return [] }
        inBuf.frameLength = AVAudioFrameCount(srcFrames)
        // Copy interleaved input → non-interleaved engine format.
        for f in 0..<srcFrames {
            for c in 0..<channels {
                chans[c][f] = pcm[f * channels + c]
            }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = max(1.0/32.0, min(32.0, rate))
        pitch.pitch = 0
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)

        let renderBlock: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: renderBlock
        )
        try engine.start()

        player.scheduleBuffer(inBuf, completionHandler: nil)
        player.play()

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: renderBlock) else {
            engine.stop()
            return []
        }
        var out: [Float] = []
        out.reserveCapacity(targetFrames * channels)

        renderLoop: while out.count / channels < targetFrames {
            let want = AVAudioFrameCount(min(Int(renderBlock), targetFrames - out.count / channels))
            let status = try engine.renderOffline(want, to: outBuf)
            switch status {
            case .success:
                let n = Int(outBuf.frameLength)
                if n == 0 { break renderLoop }
                guard let outChans = outBuf.floatChannelData else { break renderLoop }
                for f in 0..<n {
                    for c in 0..<channels {
                        out.append(outChans[c][f])
                    }
                }
            case .insufficientDataFromInputNode:
                break renderLoop
            case .cannotDoInCurrentContext:
                break renderLoop
            case .error:
                break renderLoop
            @unknown default:
                break renderLoop
            }
        }
        engine.stop()

        // Pad / trim to exactly targetFrames so timeline alignment is exact.
        let needed = targetFrames * channels
        if out.count < needed {
            out.append(contentsOf: Array(repeating: 0, count: needed - out.count))
        } else if out.count > needed {
            out.removeLast(out.count - needed)
        }
        return out
    }

    /// Sum a same-rate, same-length interleaved PCM buffer into the output mix.
    private static func accumulate(
        src: [Float], srcChannels: Int,
        into mix: inout [Float], outFrames: Int, outChannels: Int,
        gain: Float
    ) {
        guard !src.isEmpty, srcChannels == outChannels, outFrames > 0 else { return }
        let srcFrames = src.count / srcChannels
        let n = min(srcFrames, outFrames) * srcChannels
        if gain == 1.0 {
            for i in 0..<n { mix[i] += src[i] }
        } else {
            for i in 0..<n { mix[i] += src[i] * gain }
        }
    }

    /// Build a CMSampleBuffer carrying interleaved 32-bit float PCM for the AAC encoder.
    private static func makePCMSampleBuffer(
        samples: [Float], frameCount: Int, channelCount: Int,
        sampleRate: Double, pts: CMTime
    ) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        let s1 = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &fmt
        )
        guard s1 == noErr, let fmt else { return nil }

        let byteCount = samples.count * 4
        var blockBuffer: CMBlockBuffer?
        let s2 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard s2 == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let s3 = samples.withUnsafeBytes { rawPtr -> OSStatus in
            guard let baseAddress = rawPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard s3 == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizes: [Int] = [4 * channelCount]
        let s4 = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )],
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard s4 == noErr else { return nil }
        return sampleBuffer
    }
}
