import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// Decodes an audio asset to a downsampled peak array (one absolute peak per
/// "bin"). Used to render a waveform on the timeline. Resolution is set by
/// `binsPerSecond` — higher = more detail, more memory.
public enum AudioWaveform {

    public struct Samples {
        public let peaks: [Float]        // 0...1 per bin
        public let binsPerSecond: Double
        public let durationSeconds: Double
    }

    public static func extract(url: URL, binsPerSecond: Double = 100) async -> Samples? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let sampleRate: Double = 48_000
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let samplesPerBin = Int(sampleRate / binsPerSecond)
        var peaks: [Float] = []
        var carry: [Float] = []     // partial bin between sample buffers
        var totalFrames: Int = 0

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
            let buf = dataPtr.withMemoryRebound(to: Float.self, capacity: frames) { ptr in
                Array(UnsafeBufferPointer(start: ptr, count: frames))
            }
            totalFrames += frames

            var work = carry + buf
            while work.count >= samplesPerBin {
                let chunk = Array(work[0..<samplesPerBin])
                var maxAbs: Float = 0
                vDSP_maxmgv(chunk, 1, &maxAbs, vDSP_Length(samplesPerBin))
                peaks.append(min(1, maxAbs))
                work = Array(work[samplesPerBin...])
            }
            carry = work
        }
        if !carry.isEmpty {
            var maxAbs: Float = 0
            vDSP_maxmgv(carry, 1, &maxAbs, vDSP_Length(carry.count))
            peaks.append(min(1, maxAbs))
        }
        let dur = Double(totalFrames) / sampleRate
        return Samples(peaks: peaks, binsPerSecond: binsPerSecond, durationSeconds: dur)
    }
}
