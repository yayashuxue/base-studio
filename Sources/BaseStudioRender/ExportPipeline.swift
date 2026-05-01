import AVFoundation
import BaseStudioCore
import CoreImage
import CoreMedia
import Foundation

public enum ExportError: Error {
    case writerSetupFailed(String)
    case sourceNotFound
    case primarySourceMissing
    case canceled
}

/// Offline render to mp4 (PRD §5b). Single-threaded by default; deterministic by
/// construction (pure renderer, fixed iteration order, fixed pixel format).
@available(macOS 13.0, *)
public final class ExportPipeline {

    public enum AudioMode: Sendable {
        case both, micOnly, systemOnly, mute
    }

    public struct Input {
        public let project: Project
        public let bundleURL: URL
        public let outputURL: URL
        public let fps: Int
        public let bitrate: Int
        public let targetSize: (width: Int, height: Int)?
        public let audioMode: AudioMode

        public init(
            project: Project, bundleURL: URL, outputURL: URL,
            fps: Int = 60, bitrate: Int = 12_000_000,
            targetSize: (width: Int, height: Int)? = nil,
            audioMode: AudioMode = .both
        ) {
            self.project = project; self.bundleURL = bundleURL
            self.outputURL = outputURL; self.fps = fps; self.bitrate = bitrate
            self.targetSize = targetSize
            self.audioMode = audioMode
        }
    }

    public var onProgress: ((Double) -> Void)?
    public private(set) var isCanceled = false

    public init() {}

    public func cancel() { isCanceled = true }

    public func run(_ input: Input) async throws -> URL {
        // 1. Resolve primary source.
        guard let primary = input.project.sources.first(where: { $0.id == SourceID.screen })
                ?? input.project.sources.first
        else { throw ExportError.primarySourceMissing }
        let primaryURL = input.bundleURL.appendingPathComponent(primary.relativeMediaPath)

        // Load recording metadata for coord conversion (display origin, point scale).
        let bundle = ProjectBundle(url: input.bundleURL)
        let meta = try JSONDecoder().decode(
            RecordingMetadata.self,
            from: try Data(contentsOf: bundle.metadataURL)
        )

        // 2. Load all sidecars; transform coords to source-pixel space, anchor PTSes to timeline-zero.
        var cursorMap: [String: [CursorPosSample]] = [:]
        var clickMap: [String: [ClickEventSample]] = [:]
        for sc in primary.sidecars {
            let url = input.bundleURL.appendingPathComponent(sc.relativePath)
            switch sc.kind {
            case .cursor:
                let (cur, clicks) = try SidecarLoader.loadCursorJSON(at: url, meta: meta)
                cursorMap[sc.streamID] = cur
                clickMap["clicks"] = clicks
            case .clicks, .audioRMS:
                continue   // M2: clicks share cursor.json; audioRMS lands later
            }
        }
        let sidecars = SidecarStreams(cursorPositions: cursorMap, clickEvents: clickMap)

        // 3. Source readers.
        let primaryReader = SequentialSourceReader(url: primaryURL)
        try await primaryReader.start()

        var randomReaders: [String: RandomAccessSourceReader] = [:]
        for src in input.project.sources where src.id != primary.id {
            let url = input.bundleURL.appendingPathComponent(src.relativeMediaPath)
            randomReaders[src.id] = RandomAccessSourceReader(url: url)
        }

        // 4. Writer. Output dims may differ from canvas dims (resolution preset).
        let canvasW = input.project.canvas.widthPx
        let canvasH = input.project.canvas.heightPx
        let outW = input.targetSize?.width ?? canvasW
        let outH = input.targetSize?.height ?? canvasH
        if FileManager.default.fileExists(atPath: input.outputURL.path) {
            try FileManager.default.removeItem(at: input.outputURL)
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: input.outputURL, fileType: .mp4)
        } catch {
            throw ExportError.writerSetupFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: input.bitrate,
                AVVideoMaxKeyFrameIntervalKey: input.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)

        // Audio writer input — mix screen.mov system audio + (optional) mic.m4a
        // into a single AAC stereo track. Source PTSes are host-clock; we map to
        // timeline by subtracting the screen recording's first-frame PTS.
        let audioOutSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutSettings)
        audioInput.expectsMediaDataInRealTime = false
        var audioInputAdded = false
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            audioInputAdded = true
        }

        guard writer.startWriting() else {
            throw ExportError.writerSetupFailed(writer.error?.localizedDescription ?? "?")
        }
        writer.startSession(atSourceTime: .zero)

        // 5. CIContext.
        let ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .useSoftwareRenderer: false,
        ])

        // 6. Iterate primary frames; reader.pts is file-time.
        let originPTS = primary.firstPTS.cmTime   // host-clock anchor of primary's first frame
        let totalDur = input.project.timelineDuration.cmTime.seconds

        let backgroundImage: CIImage? = input.project.backgroundImageRel
            .flatMap { BackgroundImageStore.loadCIImage(filename: $0) }

        // File-time conversion: AVAssetWriter shifts each source's track to
        // start at 0, so seeks must use SourceClip.fileTime(at:).
        let sourcesByID = input.project.sourcesByID

        var currentTimelinePTS = CMTime.zero

        let frameProvider: (String, CMTime) -> CIImage? = { [weak self] sourceID, _ in
            guard let self,
                  let r = randomReaders[sourceID],
                  let src = sourcesByID[sourceID] else { return nil }
            let hostTarget = CMTimeAdd(currentTimelinePTS, originPTS)
            return self.syncFetch(r, at: src.fileTime(at: hostTarget))
        }

        // Trim window: reader.pts is file-time, so compare in file-time.
        // sidecarOffset stays in host-time (sidecar streams use host PTS).
        let segIn = input.project.videoTrack.segments.first?.sourceIn.cmTime ?? originPTS
        let segOut = input.project.videoTrack.segments.first?.sourceOut.cmTime
            ?? CMTimeAdd(originPTS, input.project.timelineDuration.cmTime)
        let segInFileTime = primary.fileTime(at: segIn)
        let segOutFileTime = primary.fileTime(at: segOut)
        let sidecarOffset = CMTimeSubtract(segIn, originPTS)

        // Compute the time map honoring speed-bearing regions.
        let timeMap = input.project.timeMap(primaryFirstPTS: originPTS)
        let timelineDurationSec = timeMap.timelineDurationSec
        let hasSpeedRemap = input.project.zoomRegions.contains { abs($0.speed - 1.0) > 0.001 }

        var frameCount = 0

        if !hasSpeedRemap {
            // Fast path: sequential read of source frames; reader.pts is file-time.
            while let frame = primaryReader.nextFrame() {
                if isCanceled { throw ExportError.canceled }
                if CMTimeCompare(frame.pts, segInFileTime) < 0 { continue }
                if CMTimeCompare(frame.pts, segOutFileTime) > 0 { break }
                let timelinePTS = CMTimeSubtract(frame.pts, segInFileTime)
                currentTimelinePTS = timelinePTS

                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try renderAndAppend(
                    project: input.project, primaryFrame: frame.image, timelinePTS: timelinePTS,
                    sidecarOffset: sidecarOffset, primary: primary,
                    sidecars: sidecars, ciContext: ciContext,
                    canvasW: canvasW, canvasH: canvasH,
                    outW: outW, outH: outH,
                    adaptor: adaptor,
                    backgroundImage: backgroundImage,
                    frameProvider: frameProvider
                )
                frameCount += 1
                if frameCount % 5 == 0, timelineDurationSec > 0 {
                    onProgress?(min(1.0, timelinePTS.seconds / timelineDurationSec))
                }
            }
        } else {
            // Speed-remap path: iterate the *output* timeline at output fps, look up
            // the source frame via TimeMap, render through nodes.
            let frameStep = 1.0 / Double(input.fps)
            let totalFrames = max(1, Int(round(timelineDurationSec / frameStep)))
            let asset = AVURLAsset(url: primaryURL)
            let imageGen = AVAssetImageGenerator(asset: asset)
            imageGen.appliesPreferredTrackTransform = true
            imageGen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
            imageGen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

            for i in 0..<totalFrames {
                if isCanceled { throw ExportError.canceled }
                let timelineSec = Double(i) * frameStep
                let timelinePTS = CMTime(seconds: timelineSec, preferredTimescale: 600)
                let sourceHostPTS = timeMap.sourcePTS(at: timelineSec, firstPTS: originPTS)
                // imageGen reads from screen.mov whose track was shifted to
                // file-time 0 by AVAssetWriter — convert host-PTS → file-time.
                let sourceFileTime = primary.fileTime(at: sourceHostPTS)
                currentTimelinePTS = timelinePTS

                guard let cg = try? imageGen.copyCGImage(at: sourceFileTime, actualTime: nil) else {
                    continue
                }
                let primaryFrame = CIImage(cgImage: cg)

                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try renderAndAppend(
                    project: input.project, primaryFrame: primaryFrame, timelinePTS: timelinePTS,
                    sidecarOffset: sidecarOffset, primary: primary,
                    sidecars: sidecars, ciContext: ciContext,
                    canvasW: canvasW, canvasH: canvasH,
                    outW: outW, outH: outH,
                    adaptor: adaptor,
                    backgroundImage: backgroundImage,
                    frameProvider: frameProvider
                )
                frameCount += 1
                if frameCount % 10 == 0, timelineDurationSec > 0 {
                    onProgress?(min(1.0, timelineSec / timelineDurationSec))
                }
            }
        }

        videoInput.markAsFinished()

        // Audio mix: AudioMixer.Source.originPTS is in *file-time* (not host).
        // Each source has its own first-frame anchor — convert per-source.
        if audioInputAdded && input.audioMode != .mute {
            let micURL = input.bundleURL.appendingPathComponent("mic.m4a")
            let hasMic = FileManager.default.fileExists(atPath: micURL.path)
            let hasSystemAudio = await assetHasAudio(primaryURL)

            var sources: [AudioMixer.Source] = []
            let useSystem = (input.audioMode == .both || input.audioMode == .systemOnly) && hasSystemAudio
            let useMic = (input.audioMode == .both || input.audioMode == .micOnly) && hasMic
            if useSystem {
                sources.append(.init(url: primaryURL, originPTS: segInFileTime, gain: 0.85))
            }
            if useMic {
                // Legacy bundles (pre-`micFirstPTS`) assumed mic shared the
                // screen anchor. micOrigin may be negative (mic started after
                // segIn) — the mixer treats that as silence until -origin.
                let micHostFirstPTS = meta.micFirstPTS?.cmTime ?? originPTS
                let micOrigin = CMTimeSubtract(segIn, micHostFirstPTS)
                sources.append(.init(url: micURL, originPTS: micOrigin, gain: 1.0))
            }

            do {
                let timelineDur = CMTime(seconds: timelineDurationSec, preferredTimescale: 600)
                try await AudioMixer.mix(
                    sources, timelineDuration: timelineDur,
                    timeMap: hasSpeedRemap ? timeMap : nil,
                    into: audioInput,
                    canceled: { [weak self] in self?.isCanceled ?? false }
                )
            } catch {
                BSLog.error("audio mix failed (\(error)); finishing video-only export.")
            }
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.writerSetupFailed(
                writer.error?.localizedDescription ?? "writer failed: \(writer.status.rawValue)"
            )
        }
        onProgress?(1.0)
        return input.outputURL
    }

    private func renderAndAppend(
        project: Project, primaryFrame: CIImage, timelinePTS: CMTime,
        sidecarOffset: CMTime, primary: SourceClip, sidecars: SidecarStreams,
        ciContext: CIContext, canvasW: Int, canvasH: Int,
        outW: Int, outH: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        backgroundImage: CIImage?,
        frameProvider: @escaping (String, CMTime) -> CIImage?
    ) throws {
        let inputs = Renderer.Inputs(
            project: project, pts: timelinePTS,
            sidecarOffset: sidecarOffset,
            primarySource: primary, primaryFrame: primaryFrame,
            sidecars: sidecars, quality: .high,
            ciContext: ciContext,
            backgroundImage: backgroundImage,
            frameProvider: frameProvider
        )
        var output = Renderer.render(inputs)
        // Scale to target output dimensions if different from canvas (resolution preset).
        if outW != canvasW || outH != canvasH {
            let sx = CGFloat(outW) / CGFloat(canvasW)
            let sy = CGFloat(outH) / CGFloat(canvasH)
            output = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ExportError.writerSetupFailed("no pixel buffer pool")
        }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pixelBuffer = pb else {
            throw ExportError.writerSetupFailed("CVPixelBufferPool failed")
        }
        ciContext.render(
            output, to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        adaptor.append(pixelBuffer, withPresentationTime: timelinePTS)
    }

    private func assetHasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
            return !tracks.isEmpty
        }
        return false
    }

    /// (Unused after AudioMixer landed; kept as fallback for single-source pass-through.)
    private func muxAudio(
        from sourceURL: URL,
        sourceFirstPTS: CMTime,
        timelineDuration: CMTime,
        into audioInput: AVAssetWriterInput
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        while let sb = output.copyNextSampleBuffer() {
            if isCanceled { return }
            // Wait for the writer to be ready.
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let originalPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            let timelinePTS = CMTimeSubtract(originalPTS, sourceFirstPTS)
            if timelinePTS.seconds < 0 || timelinePTS > timelineDuration { continue }

            // Re-anchor by creating a new sample buffer with adjusted timing.
            if let adjusted = retimedSampleBuffer(sb, newPTS: timelinePTS) {
                audioInput.append(adjusted)
            }
        }
    }

    private func retimedSampleBuffer(_ sb: CMSampleBuffer, newPTS: CMTime) -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(sb)
        guard count > 0 else { return nil }
        var timing = CMSampleTimingInfo()
        var ttArr = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(), count: count
        )
        var ttCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sb, entryCount: count, arrayToFill: &ttArr, entriesNeededOut: &ttCount
        )
        if ttCount == 0 {
            CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
            timing.presentationTimeStamp = newPTS
            var out: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sb,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &out
            )
            return out
        }
        // Many timing entries: shift all PTSes by the delta.
        let originalPTS = ttArr[0].presentationTimeStamp
        let delta = CMTimeSubtract(newPTS, originalPTS)
        for i in 0..<count {
            ttArr[i].presentationTimeStamp = CMTimeAdd(ttArr[i].presentationTimeStamp, delta)
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sb,
            sampleTimingEntryCount: count, sampleTimingArray: ttArr,
            sampleBufferOut: &out
        )
        return out
    }

    // Synchronous wrapper for the random-access reader inside the render loop.
    private func syncFetch(_ r: RandomAccessSourceReader, at t: CMTime) -> CIImage? {
        let sem = DispatchSemaphore(value: 0)
        var result: CIImage?
        Task { result = await r.frame(at: t); sem.signal() }
        sem.wait()
        return result
    }
}
