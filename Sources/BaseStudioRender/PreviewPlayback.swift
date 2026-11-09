import AVFoundation
import BaseStudioCore
import CoreImage
import Foundation

/// Editor playback as one AVPlayer item: screen + webcam video and the audio
/// laid on the timeline through the project's TimeMap (trim, cuts, speed),
/// drawn frame by frame by `PreviewCompositor` — the same `Renderer` export
/// uses. AVPlayer decodes in hardware, renders off the main thread and keeps
/// picture and sound on one clock: late frames are dropped, never delayed.
/// (The old preview rendered on the main thread at ~0.5 s a frame on a busy
/// Mac, so picture lagged sound and the webcam stuttered.)
public enum PreviewPlayback {

    public struct Context {
        public let project: Project
        public let timeMap: TimeMap
        public let primary: SourceClip
        public let sidecars: SidecarStreams
        public let backgroundImage: CIImage?
        public init(project: Project, timeMap: TimeMap, primary: SourceClip,
                    sidecars: SidecarStreams, backgroundImage: CIImage?) {
            self.project = project; self.timeMap = timeMap; self.primary = primary
            self.sidecars = sidecars; self.backgroundImage = backgroundImage
        }
    }

    /// Picture at `scale` of the canvas (playback; scrubbing still renders full size).
    public static func makeItem(_ ctx: Context, bundleURL: URL, audio: [AudioMixer.Source],
                                scale: Double = 0.4) async throws -> AVPlayerItem {
        let comp = AVMutableComposition()
        let map = ctx.timeMap
        let segIn = ctx.project.videoTrack.segments.first?.sourceIn.cmTime ?? ctx.primary.firstPTS.cmTime

        // Video: each source read at the same host time as the timeline needs.
        var trackIDs: [String: CMPersistentTrackID] = [:]
        for src in ctx.project.sources {
            let asset = AVURLAsset(url: bundleURL.appendingPathComponent(src.relativeMediaPath))
            guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first,
                  let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let range = try await srcTrack.load(.timeRange)
            // File time of trim-in for this source (negative if it began later).
            let origin = CMTimeSubtract(segIn, src.firstPTS.cmTime).seconds
            try lay(track, from: srcTrack, mediaRange: range, origin: origin, map: map)
            trackIDs[src.id] = track.trackID
        }
        for src in audio {
            let asset = AVURLAsset(url: src.url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try lay(track, from: srcTrack, mediaRange: try await srcTrack.load(.timeRange),
                    origin: src.originPTS.seconds, map: map)
        }

        let item = AVPlayerItem(asset: comp)
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(comp.tracks(withMediaType: .audio), audio).map { track, src in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(src.gain, at: .zero)
            return p
        }
        item.audioMix = mix
        item.audioTimePitchAlgorithm = .spectral

        if let screenID = trackIDs[ctx.primary.id] {
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = PreviewCompositor.self
            vc.frameDuration = CMTime(value: 1, timescale: 24)   // editor preview, like the old 24 fps knob
            vc.renderSize = CGSize(width: Double(ctx.project.canvas.widthPx) * scale,
                                   height: Double(ctx.project.canvas.heightPx) * scale)
            vc.instructions = [PreviewInstruction(
                // Must cover the composition exactly: AVPlayer silently draws
                // nothing for an instruction that falls short of the duration
                // (an asset reader is lenient), so use the composition's own.
                timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                screenTrack: screenID, webcamTrack: trackIDs[SourceID.webcam], context: ctx, scale: scale)]
            // Both "invalid" and "couldn't validate" fall back (the caller
            // catches): never hand the player a composition it may not draw.
            let valid: Bool
            do {
                valid = try await vc.isValid(for: comp, timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                                             validationDelegate: nil)
            } catch {
                throw NSError(domain: "BaseStudio.Preview", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "couldn't validate preview composition: \(error.localizedDescription)"])
            }
            guard valid else {
                throw NSError(domain: "BaseStudio.Preview", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "preview video composition is invalid"])
            }
            item.videoComposition = vc
        }
        return item
    }

    /// Insert `srcTrack` along the TimeMap: timeline piece [t0, t1) shows file
    /// time `origin + sourceStart …`; speed pieces are scaled; parts the file
    /// doesn't cover stay empty.
    static func lay(_ track: AVMutableCompositionTrack, from srcTrack: AVAssetTrack,
                    mediaRange: CMTimeRange, origin: Double, map: TimeMap) throws {
        let ts: CMTimeScale = 6000
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }
        let m0 = mediaRange.start.seconds, m1 = mediaRange.end.seconds
        for seg in map.timelineSegments() {
            let want0 = origin + seg.sourceStart, want1 = origin + seg.sourceEnd
            let have0 = max(want0, m0), have1 = min(want1, m1)
            guard have1 > have0 else { continue }
            let at = seg.timelineStart + (have0 - want0) / seg.speed
            let range = CMTimeRange(start: t(have0), end: t(have1))
            try track.insertTimeRange(range, of: srcTrack, at: t(at))
            if abs(seg.speed - 1) > 0.001 {
                track.scaleTimeRange(CMTimeRange(start: t(at), duration: range.duration),
                                     toDuration: t((have1 - have0) / seg.speed))
            }
        }
    }
}

final class PreviewInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let webcamTrack: CMPersistentTrackID?
    let context: PreviewPlayback.Context
    let scale: Double

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, webcamTrack: CMPersistentTrackID?,
         context: PreviewPlayback.Context, scale: Double) {
        self.timeRange = timeRange
        self.screenTrack = screenTrack
        self.webcamTrack = webcamTrack
        self.context = context
        self.scale = scale
        self.requiredSourceTrackIDs = ([screenTrack] + (webcamTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Draws each playback frame with `Renderer` from the decoded source frames.
final class PreviewCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        // Native decoder output first: no per-frame YUV→BGRA conversion.
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
    // Concurrent: the player asks for frames ahead; CIContext is thread-safe.
    private let queue = DispatchQueue(label: "BaseStudio.PreviewCompositor", qos: .userInteractive, attributes: .concurrent)

    /// Probe only (BS_PREVIEW_TRIVIAL=1): pass the screen frame through.
    static let trivial = ProcessInfo.processInfo.environment["BS_PREVIEW_TRIVIAL"] == "1"
    /// Probe statistics, behind a lock (frames compose concurrently).
    struct Stats { var frames = 0; var buildMs = 0.0; var drawMs = 0.0; var lastError: String? }
    private static let statsLock = NSLock()
    nonisolated(unsafe) private static var _stats = Stats()
    static var stats: Stats { statsLock.withLock { _stats } }
    static func record(_ f: (inout Stats) -> Void) { statsLock.withLock { f(&_stats) } }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [ciContext] in autoreleasepool {
            // Per-frame pool: CIImage graphs and decoded frames are
            // autoreleased (export once grew to 40 GB without one).
            guard let ins = request.videoCompositionInstruction as? PreviewInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                PreviewCompositor.record { $0.lastError = "no instruction or output buffer" }
                request.finish(with: NSError(domain: "BaseStudio.Preview", code: 1))
                return
            }
            guard let screenPB = request.sourceFrame(byTrackID: ins.screenTrack) else {
                // Nothing to show here (e.g. before the first frame): black.
                ciContext.render(CIImage(color: .black), to: out)
                request.finish(withComposedVideoFrame: out)
                return
            }
            if PreviewCompositor.trivial {   // probe: pipeline + decode cost only
                request.finish(withComposedVideoFrame: screenPB)
                return
            }
            let ctx = ins.context
            let pts = request.compositionTime
            let webcam = ins.webcamTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            let segIn = ctx.project.videoTrack.segments.first?.sourceIn.cmTime ?? ctx.primary.firstPTS.cmTime
            var inputs = Renderer.Inputs(
                project: ctx.project, pts: pts,
                sourceTime: CMTime(seconds: ctx.timeMap.sourceSec(at: pts.seconds), preferredTimescale: 6000),
                sidecarOffset: ctx.primary.fileTime(at: segIn),
                primarySource: ctx.primary, primaryFrame: CIImage(cvPixelBuffer: screenPB),
                sidecars: ctx.sidecars, quality: .standard, ciContext: ciContext,
                backgroundImage: ctx.backgroundImage,
                frameProvider: { id, _ in id == SourceID.webcam ? webcam : nil }
            )
            inputs.renderScale = ins.scale     // compute at preview size, not full then shrink
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = Renderer.render(inputs)
            let t1 = CFAbsoluteTimeGetCurrent()
            ciContext.render(image, to: out)
            let t2 = CFAbsoluteTimeGetCurrent()
            PreviewCompositor.record { $0.frames += 1; $0.buildMs += (t1 - t0) * 1000; $0.drawMs += (t2 - t1) * 1000 }
            request.finish(withComposedVideoFrame: out)
        } }
    }
}
