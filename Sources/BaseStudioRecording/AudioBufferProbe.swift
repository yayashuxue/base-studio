import CoreMedia
import Foundation

/// Cheap silence detector for diagnostics. Walks the sample buffer's raw
/// bytes at a stride and returns `true` as soon as any byte is non-zero.
/// This is good enough to distinguish "device delivered real audio" from
/// "device produced an all-zero buffer" — which is exactly the failure mode
/// we hit when a Bluetooth device negotiates an output-only profile.
///
/// Not a substitute for `AudioLevels` (which computes RMS for the UI meter).
enum AudioBufferProbe {
    static func containsNonZeroSample(_ buffer: CMSampleBuffer, stride: Int = 64) -> Bool {
        guard let bb = CMSampleBufferGetDataBuffer(buffer) else { return false }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
                bb, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &dataPointer
              ) == noErr,
              let dataPointer, length > 0 else { return false }
        let step = max(1, stride)
        var i = 0
        while i < length {
            if dataPointer[i] != 0 { return true }
            i += step
        }
        return false
    }
}
