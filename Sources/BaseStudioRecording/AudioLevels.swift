import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// Tiny shared object that holds the most recent peak level (0...1) for mic and
/// system audio. Both recorders push samples into it; the UI reads it from the
/// main thread on a timer.
public final class AudioLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: Float = 0
    private var _system: Float = 0

    public init() {}

    public var mic: Float {
        lock.lock(); defer { lock.unlock() }
        return _mic
    }
    public var system: Float {
        lock.lock(); defer { lock.unlock() }
        return _system
    }

    public func reset() {
        lock.lock(); _mic = 0; _system = 0; lock.unlock()
    }

    /// Compute peak from a CMSampleBuffer that carries 32-bit float PCM (linear).
    /// Decays toward 0 with a small smoothing factor so the meter doesn't jitter.
    public func ingest(sampleBuffer: CMSampleBuffer, channel: Channel) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>? = nil
        CMBlockBufferGetDataPointer(
            block, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &totalLen,
            dataPointerOut: &dataPtr
        )
        guard let dataPtr else { return }
        // Determine format: float vs int16. Most macOS captures land as Float32.
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        else { return }

        var peak: Float = 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let totalSamples = frames * channels

        if isFloat && asbd.mBitsPerChannel == 32 {
            dataPtr.withMemoryRebound(to: Float.self, capacity: totalSamples) { ptr in
                vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(totalSamples))
            }
            peak = min(1, peak)
        } else if asbd.mBitsPerChannel == 16 {
            dataPtr.withMemoryRebound(to: Int16.self, capacity: totalSamples) { ptr in
                var maxAbs: Int32 = 0
                for i in 0..<totalSamples {
                    let v = Int32(ptr[i])
                    let a = abs(v)
                    if a > maxAbs { maxAbs = a }
                }
                peak = Float(maxAbs) / 32768.0
            }
        }

        update(channel: channel, newPeak: peak)
    }

    public enum Channel { case mic, system }

    private func update(channel: Channel, newPeak: Float) {
        let alpha: Float = 0.4   // smoothing toward newer peak
        lock.lock()
        switch channel {
        case .mic:
            _mic = max(newPeak, _mic * (1 - alpha))
        case .system:
            _system = max(newPeak, _system * (1 - alpha))
        }
        lock.unlock()
    }
}
