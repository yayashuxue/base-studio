import AVFoundation
import BaseStudioCore
import CoreMedia
import Foundation

public enum WebcamRecorderError: Error {
    case noDevice
    case permissionDenied
    case writerSetupFailed(String)
    case alreadyRunning
}

/// Parallel AVCaptureSession recording the default camera to `webcam.mov`.
/// Runs alongside `ScreenRecorder` and shares the host clock — so the webcam's
/// frame PTSes line up with screen-frame PTSes for trivial alignment in the
/// renderer (PRD §1 invariant 2).
public final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    public struct Result {
        public let firstPTS: CMTime
        public let lastPTS: CMTime
        public let widthPx: Int
        public let heightPx: Int
    }

    private let queue = DispatchQueue(label: "BaseStudio.Webcam")
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var widthPx: Int = 0
    private var heightPx: Int = 0
    private var isRunning = false

    public override init() { super.init() }

    public func start(outputURL: URL) async throws {
        guard !isRunning else { throw WebcamRecorderError.alreadyRunning }

        // Permission.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw WebcamRecorderError.permissionDenied }
        } else if status != .authorized {
            throw WebcamRecorderError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw WebcamRecorderError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(input) else {
            throw WebcamRecorderError.writerSetupFailed("cannot add camera input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = false
        guard session.canAddOutput(output) else {
            throw WebcamRecorderError.writerSetupFailed("cannot add video output")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        // AVCaptureSession's master/synchronizationClock is already aligned to the
        // host clock on macOS, so PTSes from this session match ScreenCaptureKit's.
        session.commitConfiguration()

        // Resolve dimensions from the active format.
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        self.widthPx = Int(dims.width)
        self.heightPx = Int(dims.height)

        // Writer.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        // NOTE on task #8 (HEVC encoder slot exhaustion hypothesis):
        // An earlier attempt added `kVTVideoEncoderSpecification_*` keys to
        // force software H.264 encoding for the webcam. The keys went into
        // `AVVideoCompressionPropertiesKey` — AVAssetWriterInput validates
        // that dict strictly and threw NSInvalidArgumentException → SIGABRT
        // on launch (crash report BaseStudio-2026-04-30-232456.ips). The
        // CORRECT placement is `AVVideoEncoderSpecificationKey` at the top
        // level, but I haven't verified that path doesn't crash differently
        // on this macOS (14.6.1) yet. Re-attempt only after a clean repro
        // of the original 0-byte screen.mov bug — a single observation isn't
        // strong evidence the slot-exhaustion hypothesis is right.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: widthPx,
            AVVideoHeightKey: heightPx,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw WebcamRecorderError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw WebcamRecorderError.writerSetupFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }

        self.session = session
        self.output = output
        self.writer = writer
        self.videoInput = videoInput
        self.firstPTS = nil
        self.lastPTS = nil

        session.startRunning()
        isRunning = true
    }

    public func stop() async -> Result {
        guard isRunning else {
            return Result(firstPTS: .zero, lastPTS: .zero, widthPx: widthPx, heightPx: heightPx)
        }
        session?.stopRunning()
        videoInput?.markAsFinished()
        await writer?.finishWriting()
        let result = Result(
            firstPTS: firstPTS ?? .zero,
            lastPTS: lastPTS ?? .zero,
            widthPx: widthPx, heightPx: heightPx
        )
        session = nil; output = nil; writer = nil; videoInput = nil
        isRunning = false
        return result
    }

    // MARK: - delegate

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid, let videoInput, videoInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = pts
            writer?.startSession(atSourceTime: pts)
        }
        lastPTS = pts
        videoInput.append(sampleBuffer)
    }
}
