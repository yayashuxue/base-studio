import AVFoundation
import VideoToolbox
import BaseStudioCore
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum ScreenRecorderError: Error, LocalizedError {
    case noDisplay
    case writerSetupFailed(String)
    case writerFailed(String)
    case noFramesWritten
    case alreadyRunning
    case notRunning
    case screenRecordingDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available."
        case .writerSetupFailed(let msg):
            return "Writer setup failed: \(msg)"
        case .writerFailed(let msg):
            return "Screen recording failed while writing video: \(msg)"
        case .noFramesWritten:
            return "Screen recording failed because no video frames were written."
        case .alreadyRunning:
            return "Screen recorder is already running."
        case .notRunning:
            return "Screen recorder is not running."
        case .screenRecordingDenied:
            return "Screen Recording permission needed. After enabling it in System Settings, you MUST quit Base Studio (⌘Q) and relaunch — macOS only picks up the new permission on a fresh launch."
        }
    }
}

/// Minimal seam over the SCStream operations `ScreenRecorder` drives, so the
/// failure / cleanup paths (add-output throw, startCapture throw, stopCapture
/// throw, output-removal on teardown) can be unit-tested with a throwing fake —
/// no live ScreenCaptureKit capture required. The production impl forwards to a
/// real `SCStream`; tests inject a fake via `ScreenRecorder.streamAdapterFactory`.
@available(macOS 13.0, *)
protocol ScreenStreamAdapter: AnyObject {
    func addOutput(_ output: SCStreamOutput, type: SCStreamOutputType, queue: DispatchQueue) throws
    func removeOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws
    func startCapture() async throws
    func stopCapture() async throws
}

@available(macOS 13.0, *)
final class RealSCStreamAdapter: ScreenStreamAdapter {
    private let stream: SCStream
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate) {
        stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    }
    func addOutput(_ output: SCStreamOutput, type: SCStreamOutputType, queue: DispatchQueue) throws {
        try stream.addStreamOutput(output, type: type, sampleHandlerQueue: queue)
    }
    func removeOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws {
        try stream.removeStreamOutput(output, type: type)
    }
    func startCapture() async throws { try await stream.startCapture() }
    func stopCapture() async throws { try await stream.stopCapture() }
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
    private var streamAdapter: ScreenStreamAdapter?
    /// Output types currently attached to `streamAdapter`, so teardown can
    /// remove exactly what was added (best-effort) before releasing.
    private var attachedOutputs: [SCStreamOutputType] = []
    /// Injectable for tests — a fake can throw at add/start/stop to exercise the
    /// rollback/cleanup paths without live capture. Production builds a real
    /// SCStream-backed adapter.
    var streamAdapterFactory: (SCContentFilter, SCStreamConfiguration, SCStreamDelegate) -> ScreenStreamAdapter = {
        RealSCStreamAdapter(filter: $0, configuration: $1, delegate: $2)
    }
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    // Mid-recording encoder recovery. VideoToolbox can invalidate a live
    // compression session (-12785 kVTInvalidSessionErr) minutes into a take
    // (sleep/wake, display reconfig, encoder pre-emption). The writer then
    // stays `.failed` and the whole screen.mov used to be lost. Now each writer
    // is a *segment*: fragmented on disk (readable up to the last fragment even
    // if it never finalizes) and, on failure, replaced by a fresh one; stop()
    // stitches the segments back onto the original timeline.
    private let writerLock = NSLock()
    private var outputURL: URL?
    private var fps: Int = 60
    private var segments: [(url: URL, start: CMTime)] = []
    private var sessionStarted = false
    private var recoveries: Int = 0
    private var lastFailureAt: CFAbsoluteTime = 0
    static let maxRecoveries = 20
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    /// Test-only fault injection (`BS_INJECT_SCREEN_FAIL_AT_FRAMES=300,900`):
    /// abandon the current segment at those appended-frame counts as if the
    /// encoder had been invalidated. Never set in normal runs.
    private var injectFailAt: Set<Int> = []
    /// Test-only (`BS_INJECT_SCREEN_CANCEL_AT_FRAMES`): cancel the writer at
    /// those counts so it turns `.cancelled` and its input stops being ready —
    /// the "dead encoder, input never ready" path, which must still roll over.
    private var injectCancelAt: Set<Int> = []
    /// Test-only (`BS_INJECT_SCREEN_FAIL_AT_SECONDS=90,200`): abandon the
    /// current segment once the take passes these times (seconds since the
    /// first frame). Time-based so long takes fail at predictable moments.
    private var injectFailAtSeconds: [Double] = []
    /// Test-only (`BS_INJECT_SCREEN_SILENCE_AFTER_SECONDS=10`): ignore every
    /// screen frame after this point, as a locked/sleeping display does.
    private var injectSilenceAfter: Double?
    public private(set) var screenRecoveryCount: Int = 0
    /// Software H.264 instead of VideoToolbox hardware (experiment: BS_FORCE_SW_ENCODER=1).
    private var useSoftwareEncoder = ProcessInfo.processInfo.environment["BS_FORCE_SW_ENCODER"] == "1"
    /// After the first encoder failure, feed the encoder our own copies of
    /// SCK's frames instead of SCK's IOSurfaces. A degraded capture stack can
    /// hand out surfaces every encoder session rejects on frame 1 (-12785),
    /// while the same writer accepts frames from our own pool (verified with
    /// --selftest-synthetic-writer). Kept as the default; see below.
    /// Default ON (the zero-copy path died on frame 1 on a real machine while
    /// copies encoded cleanly); BS_SCREEN_ZERO_COPY=1 restores zero-copy, and
    /// even then the first encoder failure switches to copies.
    private var copyFrames = ProcessInfo.processInfo.environment["BS_SCREEN_ZERO_COPY"] != "1"
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pendingAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var copyDropsNoPool = 0
    private var copyIdleFrames = 0
    /// Last frame actually encoded + its time. SCK sends no picture while the
    /// screen is static, so without a closing frame the video track ended at
    /// the last *change* (5.2 s of an 8 s take) and export cut the tail —
    /// audio included. stop() re-appends this frame at the take's end.
    private var lastEncodedFrame: CVPixelBuffer?
    private var lastEncodedPTS: CMTime?
    /// Our own NV12 pool for copied frames — the adaptor's pool stays nil for
    /// the first seconds of a session, which dropped ~60 % of frames.
    private var copyPool: CVPixelBufferPool?
    private var copyDropsAlloc = 0
    private let captureSystemAudio: Bool
    private var firstPTS: CMTime?
    private var firstAudioPTS: CMTime?
    private var lastPTS: CMTime?
    private var screenFramesReceived: Int = 0
    private var screenFramesFiltered: Int = 0
    private var screenFramesNotReady: Int = 0
    private var screenFramesAppended: Int = 0
    private var screenAppendFailures: Int = 0
    private var firstAppendFailure: String?
    private var writerHasFailed: Bool = false
    // Written on the SCK delegate queue, read on the stop() thread → guard with
    // a lock. `@unchecked Sendable` alone would only hide the data race.
    private let stopErrorLock = NSLock()
    private var _streamStopError: Error?
    private func setStreamStopError(_ e: Error?) {
        stopErrorLock.lock(); _streamStopError = e; stopErrorLock.unlock()
    }
    private func readStreamStopError() -> Error? {
        stopErrorLock.lock(); defer { stopErrorLock.unlock() }; return _streamStopError
    }
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
            // Capture at the display's TRUE physical (framebuffer) pixels.
            //
            // `SCDisplay.width/height` is documented in *points*, and on this
            // macOS (14.6.1) it returns points too — e.g. 1512×982 for a 14"
            // Retina MBP whose real backing store is 3024×1964. Feeding SCK
            // config.width = 1512 recorded the screen at HALF resolution, so
            // playback on a Retina panel looked soft (the "quality is worse
            // than Cap/Screen Studio" symptom). An earlier revision instead
            // hard-assumed SCDisplay was already pixels — the opposite error.
            //
            // Resolve it unambiguously via CGDisplayCopyDisplayMode's
            // pixelWidth/pixelHeight (the framebuffer size, version-independent),
            // and only fall back to points × backingScaleFactor if that's
            // unavailable. `clampToEncoderLimit` then guards the -12785 /
            // 0-byte VideoToolbox ceiling the old comment worried about, so we
            // get full resolution WITHOUT risking the encoder blowup.
            let physical = Self.physicalPixels(
                displayID: display.displayID,
                pointWidth: display.width, pointHeight: display.height,
                scale: scale
            )
            widthPx = physical.0
            heightPx = physical.1
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
        // Feed VideoToolbox a native YUV format. BGRA capture forces the encoder
        // through a conversion path that can fail shortly after start on the
        // built-in Retina display with -16122, leaving a 36-byte screen.mov.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        config.capturesAudio = captureSystemAudio
        if captureSystemAudio {
            config.excludesCurrentProcessAudio = true   // avoid feedback if our app makes noise
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        self.widthPx = widthPxFinal
        self.heightPx = heightPxFinal
        self.fps = fps
        self.outputURL = outputURL
        let (writer, videoInput, audioInput) = try makeSegmentWriter(url: outputURL)
        self.segments = [(outputURL, .invalid)]
        self.sessionStarted = false
        self.recoveries = 0
        self.screenRecoveryCount = 0
        self.lastFailureAt = 0
        self.injectFailAt = Self.frameList("BS_INJECT_SCREEN_FAIL_AT_FRAMES")
        self.injectCancelAt = Self.frameList("BS_INJECT_SCREEN_CANCEL_AT_FRAMES")
        self.injectSilenceAfter = ProcessInfo.processInfo.environment["BS_INJECT_SCREEN_SILENCE_AFTER_SECONDS"].flatMap(Double.init)
        self.injectFailAtSeconds = (ProcessInfo.processInfo.environment["BS_INJECT_SCREEN_FAIL_AT_SECONDS"] ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted()
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = pendingAdaptor
        self.firstPTS = nil
        self.firstAudioPTS = nil
        self.lastPTS = nil
        self.screenFramesReceived = 0
        self.screenFramesFiltered = 0
        self.screenFramesNotReady = 0
        self.screenFramesAppended = 0
        self.screenAppendFailures = 0
        self.audioBuffersReceived = 0
        self.audioBuffersNonSilent = 0
        self.firstAppendFailure = nil
        self.writerHasFailed = false
        setStreamStopError(nil)

        // From here the AVAssetWriter is in `.writing`. If SCStream setup or
        // startCapture throws, we MUST cancel the writer and drop every handle —
        // otherwise a failed start leaks a live `.writing` AVAssetWriter (and
        // possibly a half-attached SCStream), which accumulates across retries
        // and poisons the media subsystem (the real cause behind what looked
        // like "machine state"). Roll back on any throw, then rethrow.
        let adapter = streamAdapterFactory(filter, config, self)
        do {
            try await attachAndStart(adapter: adapter, captureAudio: captureSystemAudio)
            self.isRunning = true
            BSLog.info("screen recorder started — displayID=\(displayUsed.displayID), size=\(widthPxFinal)x\(heightPxFinal), fps=\(fps), pixelFormat=420v, codec=h264, systemAudio=\(captureSystemAudio), softwareEncoder=\(useSoftwareEncoder)")
        } catch {
            BSLog.error("screen start failed after startWriting — rolling back writer/stream: \(error)")
            // Best-effort remove the outputs we attached + stop the possibly-
            // partially-started stream, cancel the writer, drop every handle.
            await teardownStream(adapter: adapter)
            writer.cancelWriting()
            resetHandles()
            throw error
        }
    }

    /// Copy an NV12 (420v) buffer into a fresh buffer from `pool`, plane by
    /// plane, so the encoder never sees the capture stack's IOSurface.
    static func copyNV12(_ src: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool, CVPixelBufferGetPlaneCount(src) == 2 else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out,
              CVPixelBufferGetPlaneCount(dst) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        for plane in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { return nil }
            let sRow = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
            let dRow = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let rows = min(CVPixelBufferGetHeightOfPlane(src, plane), CVPixelBufferGetHeightOfPlane(dst, plane))
            let n = min(sRow, dRow)
            for r in 0..<rows { memcpy(d + r * dRow, s + r * sRow, n) }
        }
        return dst
    }

    static func makeNV12Pool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &pool)
        return pool
    }

    static func frameList(_ env: String) -> Set<Int> {
        Set((ProcessInfo.processInfo.environment[env] ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    static func writerIsDead(_ status: AVAssetWriter.Status) -> Bool {
        status == .failed || status == .cancelled
    }

    /// The writer/inputs of the *current* segment. A rollover can swap them on
    /// the screen queue, so stop() must re-read after draining the queues.
    func currentAdaptor() -> AVAssetWriterInputPixelBufferAdaptor? {
        writerLock.lock(); defer { writerLock.unlock() }
        return adaptor
    }

    func currentHandles() -> (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?) {
        writerLock.lock(); defer { writerLock.unlock() }
        return (writer, videoInput, audioInput)
    }

    /// Build one started segment writer (H.264 + optional system-audio AAC),
    /// fragmented every 2 s so a segment whose encoder dies is still readable.
    private func makeSegmentWriter(url: URL) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?) {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ScreenRecorderError.writerSetupFailed(error.localizedDescription)
        }
        writer.movieFragmentInterval = Self.fragmentInterval
        // H.264 for the recorded source. Keep the broadly compatible codec, but
        // pair it with NV12 frames so VideoToolbox does not have to encode
        // SCK's BGRA buffers directly.
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: widthPx,
            AVVideoHeightKey: heightPx,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, widthPx * heightPx * fps / 12),
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        if useSoftwareEncoder {
            // Hardware H.264 sessions can be dead on arrival (-12785/-16122 on
            // frame 1) when the media stack is degraded; Apple's software
            // encoder is slower but independent of that state.
            videoSettings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecorderError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: widthPx,
            kCVPixelBufferHeightKey as String: heightPx,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        self.pendingAdaptor = adaptor

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
        return (writer, videoInput, audioInput)
    }

    /// The current segment's encoder died (or a test injected that). Leave its
    /// fragmented file on disk as-is and open the next segment; the next frame
    /// starts its session. Called on the screen queue.
    private func rollOverSegment(reason: String) {
        guard let base = outputURL else { writerHasFailed = true; return }
        recoveries += 1
        lastFailureAt = CFAbsoluteTimeGetCurrent()
        if !copyFrames {
            copyFrames = true
            BSLog.warn("switching screen encoding to copied frames after encoder failure")
        }
        guard recoveries <= Self.maxRecoveries else {
            BSLog.error("screen encoder failed again (\(reason)); giving up after \(Self.maxRecoveries) recoveries")
            writerHasFailed = true
            return
        }
        let url = base.deletingLastPathComponent()
            .appendingPathComponent("screen.part\(recoveries).mov")
        try? FileManager.default.removeItem(at: url)
        do {
            let (w, v, a) = try makeSegmentWriter(url: url)
            writerLock.lock()
            writer = w; videoInput = v; audioInput = a; adaptor = pendingAdaptor; sessionStarted = false
            segments.append((url, .invalid))
            writerLock.unlock()
            screenRecoveryCount = recoveries
            BSLog.warn("screen encoder failed (\(reason)) — continuing in \(url.lastPathComponent)")
        } catch {
            BSLog.error("could not open a replacement screen segment: \(error)")
            writerHasFailed = true
        }
    }

    /// Put the segments back onto the original timeline (gaps stay gaps, so
    /// screen stays in sync with webcam/mic) and write `outputURL`. Segments
    /// that hold no readable video are skipped.
    static func stitch(segments: [(url: URL, start: CMTime)], origin: CMTime, into outputURL: URL) async throws {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ScreenRecorderError.writerFailed("stitch: cannot create video track") }
        var aTrack: AVMutableCompositionTrack?
        var usable = 0
        var transform: CGAffineTransform?
        for seg in segments where seg.start.isValid {
            let asset = AVURLAsset(url: seg.url)
            guard let v = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = (try? await v.load(.timeRange)) ?? .zero
            guard range.duration.seconds > 0 else { continue }
            // File time 0 of a segment is its session start (= seg.start on
            // the host clock). Media at file time t belongs at offset + t, so
            // each track is placed by its OWN start — audio usually begins a
            // little after the first frame; anchoring it at the segment start
            // would pull it early and break A/V sync.
            let offset = CMTimeMaximum(.zero, CMTimeSubtract(seg.start, origin))
            try vTrack.insertTimeRange(range, of: v, at: CMTimeAdd(offset, range.start))
            if transform == nil { transform = try? await v.load(.preferredTransform) }
            if let a = try? await asset.loadTracks(withMediaType: .audio).first {
                let ar = (try? await a.load(.timeRange)) ?? .zero
                if ar.duration.seconds > 0 {
                    if aTrack == nil {
                        aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try? aTrack?.insertTimeRange(ar, of: a, at: CMTimeAdd(offset, ar.start))
                }
            }
            usable += 1
        }
        guard usable > 0 else { throw ScreenRecorderError.noFramesWritten }
        if let transform { vTrack.preferredTransform = transform }
        let tmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent("screen.stitching-\(UUID().uuidString).mov")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ScreenRecorderError.writerFailed("stitch: no passthrough export session")
        }
        export.outputURL = tmp
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw ScreenRecorderError.writerFailed("stitch export failed: \(String(describing: export.error))")
        }
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tmp, to: outputURL)
        for seg in segments where seg.url != outputURL { try? FileManager.default.removeItem(at: seg.url) }
    }

    /// Attach the screen (+ optional audio) outputs and start capture on the
    /// adapter, recording which outputs were added so teardown removes exactly
    /// those. Extracted + `internal` so a throwing fake adapter can exercise the
    /// add-output / startCapture failure paths without live capture.
    func attachAndStart(adapter: ScreenStreamAdapter, captureAudio: Bool) async throws {
        self.streamAdapter = adapter
        attachedOutputs = []
        try adapter.addOutput(self, type: .screen, queue: screenQueue)
        attachedOutputs.append(.screen)
        if captureAudio {
            try adapter.addOutput(self, type: .audio, queue: audioQueue)
            attachedOutputs.append(.audio)
        }
        try await adapter.startCapture()
    }

    /// Best-effort detach + stop of the stream. Removing outputs first stops new
    /// sample-handler callbacks from being delivered before we drop the input
    /// handles (a stopCapture that threw may still be producing frames). Does
    /// not touch writer/state — the caller owns those.
    func teardownStream(adapter: ScreenStreamAdapter) async {
        for type in attachedOutputs { try? adapter.removeOutput(self, type: type) }
        attachedOutputs = []
        try? await adapter.stopCapture()
    }

    // Test-only observers of teardown state.
    var isCapturing: Bool { isRunning }
    var hasStreamAdapter: Bool { streamAdapter != nil }
    var attachedOutputCount: Int { attachedOutputs.count }

    /// Drop every capture handle and return to non-running. Single source of
    /// truth for teardown so no failure path forgets one. Internal for tests.
    func resetHandles() {
        self.streamAdapter = nil
        self.attachedOutputs = []
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.isRunning = false
    }

    /// True physical (framebuffer) pixel size of a display, clamped to a safe
    /// H.264 encoder ceiling and rounded to even dimensions.
    ///
    /// `CGDisplayCopyDisplayMode(_:).pixelWidth/pixelHeight` is the framebuffer
    /// size in real pixels regardless of whether SCK reported points or pixels,
    /// so it resolves the points-vs-pixels ambiguity that caused half-res
    /// capture. Falls back to `pointW/H × scale` if the mode is unavailable.
    static func physicalPixels(
        displayID: CGDirectDisplayID,
        pointWidth: Int, pointHeight: Int, scale: Double
    ) -> (Int, Int) {
        // ⚠️ REVERTED to the SCDisplay dimensions (the original behaviour).
        //
        // History: I "fixed" soft recordings by capturing at the true
        // framebuffer pixels (CGDisplayCopyDisplayMode → 3024×1964 on a 14"
        // MBP). That REGRESSED real recordings to -12785 (kVTInvalidSessionErr)
        // mid-record — SCK's large IOSurface queue + the ~29 Mbps H.264 stream +
        // the concurrent webcam/mic sessions tip the media subsystem over, and
        // screen.mov comes back corrupt (moov missing) → "couldn't open the
        // file". The pre-existing code sat at the SCDisplay value precisely to
        // dodge this (its comment was wrong about *why* — it's points, not
        // pixels — but the value was proven-safe: real recordings finalized).
        //
        // I cannot verify any higher value from here: headless xctest can't
        // exercise VideoToolbox (it -12785s regardless of resolution, a
        // window-server-session artifact), and I can't drive the GUI recorder.
        // So reliability wins — capture at the proven-safe SCDisplay dims. The
        // crispness improvement is deferred until it can be validated with real
        // multi-round GUI recordings (screen + webcam + mic).
        _ = scale
        _ = displayID
        return clampToEncoderLimit(pointWidth, pointHeight)
    }

    /// Clamp to `maxDimension` on the long edge (preserving aspect) and force
    /// even width/height. Guards the VideoToolbox -12785 ceiling that produced
    /// 0-byte/36-byte screen.mov files when dimensions were doubled by mistake.
    static func clampToEncoderLimit(_ w: Int, _ h: Int, maxDimension: Int = 4096) -> (Int, Int) {
        var fw = Double(max(w, 2))
        var fh = Double(max(h, 2))
        let longEdge = max(fw, fh)
        if longEdge > Double(maxDimension) {
            let k = Double(maxDimension) / longEdge
            fw *= k
            fh *= k
        }
        let ew = (Int(fw.rounded()) >> 1) << 1
        let eh = (Int(fh.rounded()) >> 1) << 1
        return (max(ew, 2), max(eh, 2))
    }

    public func stop() async throws -> Result {
        guard isRunning, let adapter = streamAdapter, writer != nil, videoInput != nil else {
            throw ScreenRecorderError.notRunning
        }
        // Always return to a clean non-running state — even if stopCapture or
        // finalize throws — so a broken stop can't leave a leaked .writing
        // AVAssetWriter behind.
        defer { resetHandles() }

        // The take ends when the user stops — not at the last frame SCK sent.
        // SCK sends nothing for a static or locked screen (a 330 s take whose
        // screen locked after 10 s had its last frame at 10 s), so the
        // timeline and the closing frame are anchored to now, on the same host
        // clock SCK stamps frames with.
        let stopHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastPTS, CMTimeCompare(stopHostTime, last) > 0 { lastPTS = stopHostTime }

        var stopCaptureError: Error?
        do {
            try await adapter.stopCapture()
        } catch {
            stopCaptureError = error
        }
        // Detach outputs so no NEW sample-handler callback is delivered, THEN
        // drain the callbacks already enqueued on the capture queues, THEN
        // (later) nil the input handle — three layers so a late frame can't
        // append to a finished input even if stopCapture threw and the stream
        // is still producing.
        for type in attachedOutputs { try? adapter.removeOutput(self, type: type) }
        attachedOutputs = []
        screenQueue.sync {}
        audioQueue.sync {}

        if let stopCaptureError {
            // Abnormal capture end — don't try to finalize a broken session.
            currentHandles().0?.cancelWriting()
            throw ScreenRecorderError.writerFailed(
                "SCStream stopCapture failed: \(stopCaptureError.localizedDescription)"
            )
        }

        // Re-read: a rollover may have happened while stopCapture()/the drain
        // ran, and that newest segment is the one to finalize.
        let (curWriter, curVideo, curAudio) = currentHandles()
        guard let writer = curWriter, let videoInput = curVideo else { throw ScreenRecorderError.notRunning }
        let audioInput = curAudio
        // The current segment may be healthy (finish it) or dead (leave its
        // fragments alone). Earlier dead segments are already on disk.
        if writer.status == .writing {
            // Hold the last picture until the end of the take (see lastEncodedFrame).
            if let frame = lastEncodedFrame, let at = lastEncodedPTS, let end = lastPTS,
               sessionStarted, CMTimeCompare(end, at) > 0, let adaptor = currentAdaptor(),
               videoInput.isReadyForMoreMediaData,
               let copy = Self.copyNV12(frame, pool: copyPool ?? Self.makeNV12Pool(width: widthPx, height: heightPx)) {
                if !adaptor.append(copy, withPresentationTime: end) {
                    BSLog.warn("closing frame not appended: \(String(describing: writer.error))")
                }
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            await writer.finishWriting()
        }
        BSLog.info("stopped — received=\(screenFramesReceived), filtered=\(screenFramesFiltered), notReady=\(screenFramesNotReady), appended=\(screenFramesAppended), segments=\(segments.count), recoveries=\(recoveries), copy idle=\(copyIdleFrames) drops(noPool/alloc)=\(copyDropsNoPool)/\(copyDropsAlloc), audio buffers=\(audioBuffersReceived) non-silent=\(audioBuffersNonSilent), writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")
        let stopError = readStreamStopError()
        guard screenFramesAppended > 0, let origin = firstPTS, let outputURL else {
            throw ScreenRecorderError.writerFailed(
                firstAppendFailure ?? stopError?.localizedDescription ?? "no screen frames were written"
            )
        }
        let clean = segments.count == 1 && writer.status == .completed
        if !clean {
            // Recovered or partial take: rebuild screen.mov from whatever is
            // readable. Only if nothing at all is readable is the take lost.
            do {
                try await Self.stitch(segments: segments, origin: origin, into: outputURL)
                BSLog.warn("screen.mov rebuilt from \(segments.count) segment(s) after \(recoveries) encoder recovery(ies)")
            } catch {
                throw ScreenRecorderError.writerFailed(
                    "\(firstAppendFailure ?? "screen encoder failed") — recovery failed: \(error)"
                )
            }
        }
        if let stopError {
            BSLog.warn("SCStream reported an error before stop (footage kept): \(stopError.localizedDescription)")
        }

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
            if let quiet = injectSilenceAfter, let origin = firstPTS,
               CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), origin).seconds > quiet {
                return
            }
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
            guard !writerHasFailed else { return }
            // After a failure, give VideoToolbox a moment before reopening.
            if lastFailureAt > 0, CFAbsoluteTimeGetCurrent() - lastFailureAt < 0.25, !sessionStarted { return }
            writerLock.lock()
            let writer = self.writer, videoInput = self.videoInput
            writerLock.unlock()
            guard let writer, let videoInput else {
                BSLog.warn("videoInput is nil; dropping frame")
                return
            }
            // A dead encoder can leave the input permanently "not ready", so the
            // append-failure branch below would never fire. Check status first.
            if Self.writerIsDead(writer.status) {
                rollOverSegment(reason: String(describing: writer.error ?? ScreenRecorderError.writerFailed("writer status \(writer.status.rawValue)")))
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
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                writerLock.lock()
                sessionStarted = true
                if let k = segments.indices.last { segments[k].start = pts }
                writerLock.unlock()
                if firstPTS == nil { firstPTS = pts }
                BSLog.info("startSession (segment \(segments.count)) at pts=\(pts.seconds), writer.status=\(writer.status.rawValue)")
            }
            lastPTS = pts
            let ok: Bool
            if copyFrames {
                writerLock.lock(); let adaptor = self.adaptor; writerLock.unlock()
                if copyPool == nil { copyPool = Self.makeNV12Pool(width: widthPx, height: heightPx) }
                guard let src = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    // SCK "idle" frame: the screen didn't change, nothing to encode.
                    copyIdleFrames += 1
                    return
                }
                guard let adaptor, let pool = copyPool else {
                    copyDropsNoPool += 1
                    return
                }
                guard let copy = Self.copyNV12(src, pool: pool) else {
                    copyDropsAlloc += 1
                    return
                }
                ok = adaptor.append(copy, withPresentationTime: pts)
                if ok { lastEncodedFrame = copy; lastEncodedPTS = pts }
            } else {
                ok = videoInput.append(sampleBuffer)
                if ok, let img = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    lastEncodedFrame = img; lastEncodedPTS = pts
                }
            }
            if !ok {
                screenAppendFailures += 1
                let msg = String(describing: writer.error)
                if firstAppendFailure == nil { firstAppendFailure = msg }
                BSLog.error("append failed (\(screenAppendFailures)), writer.status=\(writer.status.rawValue), writer.error=\(msg)")
                if Self.writerIsDead(writer.status) {
                    rollOverSegment(reason: msg)
                }
                return
            }
            screenFramesAppended += 1
            if screenFramesAppended % 60 == 1 {
                BSLog.info("appended \(screenFramesAppended) frames")
            }
            if let next = injectFailAtSeconds.first, let origin = firstPTS,
               CMTimeSubtract(pts, origin).seconds >= next {
                injectFailAtSeconds.removeFirst()
                BSLog.warn("BS_INJECT_SCREEN_FAIL_AT_SECONDS: abandoning segment at \(CMTimeSubtract(pts, origin).seconds)s")
                rollOverSegment(reason: "injected at \(next)s")
                return
            }
            if injectFailAt.contains(screenFramesAppended) {
                BSLog.warn("BS_INJECT_SCREEN_FAIL_AT_FRAMES: abandoning segment at frame \(screenFramesAppended)")
                rollOverSegment(reason: "injected")
            }
            if injectCancelAt.contains(screenFramesAppended) {
                BSLog.warn("BS_INJECT_SCREEN_CANCEL_AT_FRAMES: cancelling writer at frame \(screenFramesAppended)")
                writer.cancelWriting()
            }
            return
        }

        if type == .audio {
            writerLock.lock()
            let audioInput = self.audioInput, open = sessionStarted
            writerLock.unlock()
            // Defer audio until video has started the (current segment's)
            // session — both share the host-clock timebase.
            guard open, let audioInput, audioInput.isReadyForMoreMediaData else { return }
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
        // Fold an async SCK stop error into the recorder's failure state so
        // stop() reports a broken capture instead of silently returning a
        // partial bundle.
        setStreamStopError(error)
    }

    static func bufferContainsAudio(_ buffer: CMSampleBuffer) -> Bool {
        AudioBufferProbe.containsNonZeroSample(buffer)
    }
}
