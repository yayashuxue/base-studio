import BaseStudioCore
import Foundation

/// Errors thrown by `RecordingSession` itself. Recorder-level errors keep
/// their own types (e.g. `WebcamRecorderError`); these are re-throws or
/// composite failures with a stable message that the UI can pattern-match
/// to choose the right "Open Settings" pane.
public enum RecordingSessionError: LocalizedError {
    case cameraPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Camera permission denied — enable it in System Settings → Privacy & Security → Camera, then try again."
        }
    }
}

/// Orchestrates a single recording: starts the screen capture (with optional
/// system audio), the cursor recorder, the webcam recorder, and the microphone
/// recorder together; stops them together; writes a `ProjectBundle` on disk.
@available(macOS 13.0, *)
public final class RecordingSession {

    public enum State { case idle, recording, finalizing }
    public private(set) var state: State = .idle

    public struct Options {
        public var includeWebcam: Bool
        public var includeSystemAudio: Bool
        public var includeMic: Bool
        public var cursorSampleHz: Int
        public var captureTarget: CaptureTarget?
        public init(
            includeWebcam: Bool = false,
            includeSystemAudio: Bool = true,
            includeMic: Bool = false,
            cursorSampleHz: Int = 120,
            captureTarget: CaptureTarget? = nil
        ) {
            self.includeWebcam = includeWebcam
            self.includeSystemAudio = includeSystemAudio
            self.includeMic = includeMic
            self.cursorSampleHz = cursorSampleHz
            self.captureTarget = captureTarget
        }
    }

    public let audioLevels = AudioLevels()
    private let options: Options
    private let screenRecorder: ScreenRecorder
    private let cursorRecorder: CursorRecorder
    private let webcamRecorder = WebcamRecorder()
    private let micRecorder: MicRecorder
    private var bundle: ProjectBundle?

    public init(options: Options = Options()) {
        self.options = options
        let levels = AudioLevels()
        self.screenRecorder = ScreenRecorder(
            captureSystemAudio: options.includeSystemAudio,
            captureTarget: options.captureTarget,
            levels: levels
        )
        self.cursorRecorder = CursorRecorder(sampleHz: options.cursorSampleHz)
        self.micRecorder = MicRecorder(levels: levels)
        // Reassign with the shared instance so audioLevels reads from the same one.
        // (audioLevels is `let`; we pass `levels` to the recorders directly.)
    }

    public var levels: AudioLevels {
        // Hand the recorders' shared levels back to the UI. Both ScreenRecorder
        // and MicRecorder were initialized with the same instance.
        screenRecorder.sharedLevels ?? audioLevels
    }

    // Back-compat convenience.
    public convenience init(cursorSampleHz: Int = 120, includeWebcam: Bool = false) {
        self.init(options: Options(
            includeWebcam: includeWebcam,
            cursorSampleHz: cursorSampleHz
        ))
    }

    public func start(in directory: URL, name: String = defaultName()) async throws -> ProjectBundle {
        precondition(state == .idle, "RecordingSession already running")
        let bundle = try ProjectBundle.create(in: directory, name: name)
        self.bundle = bundle
        state = .recording

        cursorRecorder.start()

        if options.includeMic {
            do {
                let url = bundle.url.appendingPathComponent("mic.m4a")
                try await micRecorder.start(outputURL: url)
            } catch {
                BSLog.warn("mic start failed: \(error)")
            }
        }

        if options.includeWebcam {
            do {
                let webcamURL = bundle.url.appendingPathComponent("webcam.mov")
                try await webcamRecorder.start(outputURL: webcamURL)
            } catch WebcamRecorderError.permissionDenied {
                // Permission errors MUST surface to the UI — silently dropping
                // the webcam track makes the failure invisible (the recording
                // appears to succeed but has no webcam, and the user never
                // sees a chance to grant access). Tear down what we already
                // started and propagate as a recognisable permission error.
                BSLog.error("webcam permission denied — aborting recording")
                _ = cursorRecorder.stop()
                if options.includeMic { _ = await micRecorder.stop() }
                state = .idle
                throw RecordingSessionError.cameraPermissionDenied
            } catch {
                // Non-permission webcam failures (e.g. no device attached)
                // remain a soft warning — recording proceeds without webcam.
                BSLog.warn("webcam start failed: \(error)")
            }
        }

        do {
            try await screenRecorder.start(outputURL: bundle.screenURL)
        } catch {
            _ = cursorRecorder.stop()
            if options.includeWebcam { _ = await webcamRecorder.stop() }
            if options.includeMic { _ = await micRecorder.stop() }
            state = .idle
            throw error
        }
        return bundle
    }

    public func stop() async throws -> ProjectBundle {
        precondition(state == .recording, "RecordingSession not running")
        state = .finalizing
        defer { state = .idle }
        guard let bundle else { fatalError("no bundle") }

        // Finalize sequentially: screen first, then webcam, then mic. The
        // earlier `async let` parallelization tripped a VideoToolbox session
        // conflict — two H.264 `AVAssetWriter.finishWriting()` calls
        // overlapping invalidates one of the encoder sessions
        // (`kVTInvalidSessionErr -12785`), and the loser writes a 0-byte .mov.
        // The Stop button cost of serializing is ~200ms; that's the right
        // trade. Don't reintroduce parallel finalize without holding a per-
        // process VTCompressionSession lock.
        let screenResult = try await screenRecorder.stop()
        let webcamResult: WebcamRecorder.Result? = options.includeWebcam
            ? await webcamRecorder.stop()
            : nil
        let micResult: MicRecorder.Result? = options.includeMic
            ? await micRecorder.stop()
            : nil
        let cursor = cursorRecorder.stop()

        let cursorData = try JSONEncoder.pretty.encode(cursor)
        try cursorData.write(to: bundle.cursorURL, options: .atomic)

        var sourceInfo: [String: SourceMediaInfo] = [
            SourceID.screen: SourceMediaInfo(
                firstVideoPTS: TimePoint(screenResult.firstPTS),
                lastVideoPTS: TimePoint(screenResult.lastPTS),
                widthPx: screenResult.widthPx,
                heightPx: screenResult.heightPx
            ),
        ]
        if let w = webcamResult, w.firstPTS != .zero {
            sourceInfo[SourceID.webcam] = SourceMediaInfo(
                firstVideoPTS: TimePoint(w.firstPTS),
                lastVideoPTS: TimePoint(w.lastPTS),
                widthPx: w.widthPx,
                heightPx: w.heightPx
            )
        }

        // micFirstPTS lets the export audio mixer convert the trim window
        // (host-time) into a file-time origin for mic.m4a. Without it, the
        // mixer would subtract host-time from the mic reader's file-time PTS
        // and produce massively negative timeline samples — the "I can't hear
        // mic OR system audio in the export" symptom.
        let micFirstPTS: TimePoint? = (micResult?.firstPTS).flatMap {
            $0 == .zero ? nil : TimePoint($0)
        }

        let meta = RecordingMetadata(
            displayID: screenResult.displayID,
            widthPx: screenResult.widthPx,
            heightPx: screenResult.heightPx,
            pointScale: screenResult.pointScale,
            displayOriginXPt: Double(screenResult.displayOriginPt.x),
            displayOriginYPt: Double(screenResult.displayOriginPt.y),
            displayWidthPt: Double(screenResult.displaySizePt.width),
            displayHeightPt: Double(screenResult.displaySizePt.height),
            firstVideoPTS: TimePoint(screenResult.firstPTS),
            lastVideoPTS: TimePoint(screenResult.lastPTS),
            sources: sourceInfo,
            micFirstPTS: micFirstPTS
        )
        let metaData = try JSONEncoder.pretty.encode(meta)
        try metaData.write(to: bundle.metadataURL, options: .atomic)

        return bundle
    }

    public static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Recording-\(f.string(from: Date()))"
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
