import AVFoundation
import BaseStudioCore
import CoreMedia
import Foundation

public enum MicRecorderError: Error {
    case noDevice
    case permissionDenied
    case writerSetupFailed(String)
    case alreadyRunning
}

/// Captures the default microphone to `mic.m4a` (AAC). Runs in parallel to
/// `ScreenRecorder`. Sample PTSes share the host clock with the screen track
/// (AVCaptureSession's master clock is the host clock on macOS).
public final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    public struct Result {
        public let firstPTS: CMTime
        public let lastPTS: CMTime
    }

    private let queue = DispatchQueue(label: "BaseStudio.Mic")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var isRunning = false

    private let levels: AudioLevels?

    public init(levels: AudioLevels? = nil) {
        self.levels = levels
        super.init()
    }

    public func start(outputURL: URL) async throws {
        guard !isRunning else { throw MicRecorderError.alreadyRunning }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw MicRecorderError.permissionDenied }
        } else if status != .authorized {
            throw MicRecorderError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicRecorderError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            throw MicRecorderError.writerSetupFailed("cannot add mic input")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else {
            throw MicRecorderError.writerSetupFailed("cannot add audio output")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        // Writer for mic.m4a (AAC).
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 96_000,
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        ai.expectsMediaDataInRealTime = true
        guard writer.canAdd(ai) else {
            throw MicRecorderError.writerSetupFailed("cannot add audio input")
        }
        writer.add(ai)
        guard writer.startWriting() else {
            throw MicRecorderError.writerSetupFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        self.writer = writer
        self.audioInput = ai
        self.session = session
        self.output = output
        self.firstPTS = nil
        self.lastPTS = nil

        session.startRunning()
        isRunning = true
    }

    public func stop() async -> Result {
        guard isRunning else { return Result(firstPTS: .zero, lastPTS: .zero) }
        session?.stopRunning()
        audioInput?.markAsFinished()
        await writer?.finishWriting()
        let r = Result(firstPTS: firstPTS ?? .zero, lastPTS: lastPTS ?? .zero)
        session = nil; output = nil; writer = nil; audioInput = nil
        isRunning = false
        return r
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = pts
            writer?.startSession(atSourceTime: pts)
        }
        lastPTS = pts
        levels?.ingest(sampleBuffer: sampleBuffer, channel: .mic)
        audioInput.append(sampleBuffer)
    }
}
