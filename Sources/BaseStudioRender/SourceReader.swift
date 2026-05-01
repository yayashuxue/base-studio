import AVFoundation
import BaseStudioCore
import CoreImage
import CoreMedia
import Foundation

public enum SourceReaderError: Error {
    case noVideoTrack
    case readerStartFailed(String)
}

/// Reads frames from one source `.mov` either sequentially (export) or by random
/// access (scrubbing). M0/M2 use the sequential path for export.
public final class SequentialSourceReader {
    public let url: URL
    private let asset: AVAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    public private(set) var nominalFrameDuration: CMTime = CMTime(value: 1, timescale: 60)
    public private(set) var firstPTS: CMTime = .zero

    public init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
    }

    public func start() async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw SourceReaderError.noVideoTrack }
        let frameDur = try await track.load(.minFrameDuration)
        if frameDur.isValid && frameDur.seconds > 0 { self.nominalFrameDuration = frameDur }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw SourceReaderError.readerStartFailed(
                reader.error?.localizedDescription ?? "unknown"
            )
        }
        self.reader = reader
        self.output = output
    }

    public struct Frame {
        public let image: CIImage
        public let pts: CMTime
    }

    public func nextFrame() -> Frame? {
        guard let output, let reader, reader.status == .reading,
              let sb = output.copyNextSampleBuffer() else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if firstPTS == .zero { firstPTS = pts }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let image = CIImage(cvPixelBuffer: pb)
        return Frame(image: image, pts: pts)
    }
}

/// Random-access reader: opens a fresh AVAssetReader per seek. Crude but correct
/// for v1 (used by WebcamOverlay to fetch a webcam frame at the screen frame's PTS).
/// A frame cache keyed by (sourceID, pts) is the right next step.
public final class RandomAccessSourceReader {
    public let url: URL
    private let asset: AVAsset
    private var cache: (CMTime, CIImage)?

    public init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
    }

    public func frame(at t: CMTime) async -> CIImage? {
        if let (ct, ci) = cache, abs(ct.seconds - t.seconds) < 0.016 { return ci }
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: t,
                duration: CMTime(value: 1, timescale: 30)
            )
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return nil }
            guard let sb = output.copyNextSampleBuffer(),
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
            let img = CIImage(cvPixelBuffer: pb)
            cache = (t, img)
            return img
        } catch {
            return nil
        }
    }
}
