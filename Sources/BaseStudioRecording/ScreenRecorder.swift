import AVFoundation
import BaseStudioCore
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum ScreenRecorderError: Error, LocalizedError {
    case noDisplay
    case writerSetupFailed(String)
    case alreadyRunning
    case notRunning
    case screenRecordingDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available."
        case .writerSetupFailed(let msg):
            return "Writer setup failed: \(msg)"
        case .alreadyRunning:
            return "Screen recorder is already running."
        case .notRunning:
            return "Screen recorder is not running."
        case .screenRecordingDenied:
            return "Screen Recording permission needed. After enabling it in System Settings, you MUST quit Base Studio (⌘Q) and relaunch — macOS only picks up the new permission on a fresh launch."
        }
    }
}

/// Whether macOS has granted Screen Recording permission to this app.
@available(macOS 13.0, *)
public func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
}

/// Triggers the macOS Screen Recording permission prompt if not yet decided.
@available(macOS 13.0, *)
@discardableResult
public func requestScreenRecordingPermission() -> Bool {
    CGRequestScreenCaptureAccess()
}

/// Wraps ScreenCaptureKit + AVAssetWriter. Writes a clean H.264 .mov with
/// `showsCursor = false` — the cursor is captured separately by `CursorRecorder`
/// so the editor can re-render it (PRD §6, smooth cursor / auto-zoom).
@available(macOS 13.0, *)
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    public struct Result {
        public let firstPTS: CMTime
        public let lastPTS: CMTime
        public let widthPx: Int
        public let heightPx: Int
        public let pointScale: Double
        public let displayID: UInt32
        public let displayOriginPt: CGPoint
        public let displaySizePt: CGSize
    }

    // Separate queues so audio buffers (~47/sec) don't starve screen frames (~60/sec).
    private let screenQueue = DispatchQueue(label: "BaseStudio.SCKScreen", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "BaseStudio.SCKAudio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let captureSystemAudio: Bool
    private var firstPTS: CMTime?
    private var firstAudioPTS: CMTime?
    private var lastPTS: CMTime?
    private var screenFramesReceived: Int = 0
    private var screenFramesFiltered: Int = 0
    private var screenFramesNotReady: Int = 0
    private var screenFramesAppended: Int = 0
    private var audioBuffersReceived: Int = 0
    private var audioBuffersNonSilent: Int = 0
    private var displayID: UInt32 = 0
    private var widthPx: Int = 0
    private var heightPx: Int = 0
    private var pointScale: Double = 1.0
    private var displayOriginPt: CGPoint = .zero
    private var displaySizePt: CGSize = .zero
    private var isRunning = false

    private let captureTarget: CaptureTarget?
    private let levels: AudioLevels?
    public var sharedLevels: AudioLevels? { levels }

    public init(
        captureSystemAudio: Bool = true,
        captureTarget: CaptureTarget? = nil,
        levels: AudioLevels? = nil
    ) {
        self.captureSystemAudio = captureSystemAudio
        self.captureTarget = captureTarget
        self.levels = levels
        super.init()
    }

    public func start(outputURL: URL, fps: Int = 60) async throws {
        guard !isRunning else { throw ScreenRecorderError.alreadyRunning }

        // Don't preflight via CGPreflightScreenCaptureAccess() — on macOS Sequoia
        // it can return stale `false` even after the user grants the renamed
        // "Screen & System Audio Recording" permission, causing a false denial.
        // Let SCK try directly; surface its real error to the UI if it fails.
        BSLog.info("preflight=\(CGPreflightScreenCaptureAccess()) — calling SCK directly")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // Translate SCK's permission errors into our typed error so the UI
            // can show Open Settings + Quit & Relaunch buttons.
            let ns = error as NSError
            BSLog.error("SCShareableContent failed code=\(ns.code) domain=\(ns.domain) — \(ns.localizedDescription)")
            if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
                || ns.code == -3801 || ns.code == -3812 {
                throw ScreenRecorderError.screenRecordingDenied
            }
            throw error
        }
        guard !content.displays.isEmpty else {
            throw ScreenRecorderError.noDisplay
        }

        // Resolve target → SCContentFilter + dimensions/origin metadata.
        let filter: SCContentFilter
        let widthPx: Int
        let heightPx: Int
        let scale: Double
        let displayUsed: SCDisplay

        switch captureTarget {
        case .window(let windowID):
            guard let win = content.windows.first(where: { $0.windowID == windowID }),
                  let display = content.displays.first(where: { $0.frame.intersects(win.frame) })
                    ?? content.displays.first
            else { throw ScreenRecorderError.noDisplay }
            displayUsed = display
            let nsScreen = NSScreen.screens.first { s in
                (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == display.displayID
            }
            scale = Double(nsScreen?.backingScaleFactor ?? 2.0)
            widthPx = Int(win.frame.width * scale)
            heightPx = Int(win.frame.height * scale)
            filter = SCContentFilter(desktopIndependentWindow: win)
            // Display-relative origin: window's origin in display space, in points.
            self.displayOriginPt = win.frame.origin
            self.displaySizePt = win.frame.size
        case .display, .none:
            let display: SCDisplay = {
                if case .display(let did) = captureTarget,
                   let m = content.displays.first(where: { $0.displayID == did }) {
                    return m
                }
                let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                              as? NSNumber)?.uint32Value
                if let mainID,
                   let m = content.displays.first(where: { $0.displayID == mainID }) {
                    return m
                }
                return content.displays[0]
            }()
            displayUsed = display
            let nsScreen = NSScreen.screens.first { s in
                (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == display.displayID
            }
            scale = Double(nsScreen?.backingScaleFactor ?? 2.0)
            widthPx = Int(Double(display.width) * scale)
            heightPx = Int(Double(display.height) * scale)
            filter = SCContentFilter(display: display, excludingWindows: [])
            self.displayOriginPt = nsScreen?.frame.origin ?? .zero
            self.displaySizePt = nsScreen?.frame.size
                ?? CGSize(width: Double(display.width), height: Double(display.height))
        }

        // Round to multiples of 2 so VideoToolbox's H.264/HEVC encoders accept
        // them without macroblock errors (was failing with -12785 on 1964×... ).
        let widthPx2 = (widthPx >> 1) << 1
        let heightPx2 = (heightPx >> 1) << 1
        self.displayID = displayUsed.displayID
        self.pointScale = scale
        self.widthPx = widthPx2
        self.heightPx = heightPx2
        let widthPxFinal = widthPx2
        let heightPxFinal = heightPx2
        let config = SCStreamConfiguration()
        config.width = widthPxFinal
        config.height = heightPxFinal
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = captureSystemAudio
        if captureSystemAudio {
            config.excludesCurrentProcessAudio = true   // avoid feedback if our app makes noise
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        // AVAssetWriter
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecorderError.writerSetupFailed(error.localizedDescription)
        }
        // HEVC over H.264 for the recorded source: hardware encoder is more
        // robust at high resolutions, accepts arbitrary dimensions, and handles
        // 6MP @ 60fps easily on any Apple Silicon Mac.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: widthPxFinal,
            AVVideoHeightKey: heightPxFinal,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, widthPxFinal * heightPxFinal * fps / 12),
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecorderError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)

        // Audio writer input (system audio from SCK).
        var audioInput: AVAssetWriterInput?
        if captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 192_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) {
                writer.add(ai)
                audioInput = ai
            }
        }

        guard writer.startWriting() else {
            throw ScreenRecorderError.writerSetupFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.firstPTS = nil
        self.firstAudioPTS = nil
        self.lastPTS = nil

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.isRunning = true
    }

    public func stop() async throws -> Result {
        guard isRunning, let stream, let writer, let videoInput else {
            throw ScreenRecorderError.notRunning
        }
        try await stream.stopCapture()
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        BSLog.info("stopped — received=\(screenFramesReceived), filtered=\(screenFramesFiltered), notReady=\(screenFramesNotReady), appended=\(screenFramesAppended), audio buffers=\(audioBuffersReceived) non-silent=\(audioBuffersNonSilent), writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")
        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.isRunning = false

        let first = firstPTS ?? .zero
        let last = lastPTS ?? .zero
        return Result(
            firstPTS: first,
            lastPTS: last,
            widthPx: widthPx,
            heightPx: heightPx,
            pointScale: pointScale,
            displayID: displayID,
            displayOriginPt: displayOriginPt,
            displaySizePt: displaySizePt
        )
    }

    // MARK: SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        if type == .screen {
            screenFramesReceived += 1
            // Skip only frames we know are unusable: stopped, suspended.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status == .stopped || status == .suspended {
                screenFramesFiltered += 1
                if screenFramesFiltered % 60 == 1 {
                    BSLog.warn("filtered screen frame status=\(status.rawValue)")
                }
                return
            }
            guard let videoInput else {
                BSLog.warn("videoInput is nil; dropping frame")
                return
            }
            guard videoInput.isReadyForMoreMediaData else {
                screenFramesNotReady += 1
                if screenFramesNotReady % 60 == 1 {
                    BSLog.warn("writer not ready, dropping frame (\(screenFramesNotReady))")
                }
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if firstPTS == nil {
                firstPTS = pts
                if let writer = writer {
                    writer.startSession(atSourceTime: pts)
                    BSLog.info("startSession at pts=\(pts.seconds), writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")
                }
            }
            lastPTS = pts
            let ok = videoInput.append(sampleBuffer)
            screenFramesAppended += 1
            if !ok {
                BSLog.error("append failed, writer.error=\(String(describing: writer?.error))")
            }
            if screenFramesAppended % 60 == 1 {
                BSLog.info("appended \(screenFramesAppended) frames")
            }
            return
        }

        if type == .audio, let audioInput, audioInput.isReadyForMoreMediaData {
            // Defer audio until video has started the session — both share the same
            // host-clock timebase, so once the writer's session is open audio appends correctly.
            guard firstPTS != nil else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if firstAudioPTS == nil { firstAudioPTS = pts }
            audioBuffersReceived += 1
            if Self.bufferContainsAudio(sampleBuffer) { audioBuffersNonSilent += 1 }
            levels?.ingest(sampleBuffer: sampleBuffer, channel: .system)
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        BSLog.error("SCStream stopped with error: \(error)")
    }

    static func bufferContainsAudio(_ buffer: CMSampleBuffer) -> Bool {
        AudioBufferProbe.containsNonZeroSample(buffer)
    }
}
