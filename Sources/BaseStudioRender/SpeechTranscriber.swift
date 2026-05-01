import AVFoundation
import BaseStudioCore
import Foundation
import Speech

/// Auto-transcribes an audio file using macOS's native `Speech` framework.
/// Prefers on-device recognition when available (offline, private). Returns a
/// list of `Caption` whose timing is in source-relative seconds; callers normalize
/// to timeline time as needed.
@available(macOS 13.0, *)
public enum SpeechTranscriber {

    public enum Error: Swift.Error {
        case permissionDenied
        case noRecognizer
        case transcriptionFailed(String)
    }

    public static func transcribe(audioURL: URL) async throws -> [Caption] {
        // Authorize.
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let granted: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { s in cont.resume(returning: s) }
            }
            if granted != .authorized { throw Error.permissionDenied }
        } else if status != .authorized {
            throw Error.permissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable
        else { throw Error.noRecognizer }
        if recognizer.supportsOnDeviceRecognition {
            // Use on-device when available.
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    cont.resume(throwing: Error.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result = result, result.isFinal else { return }
                let captions = chunkSegments(result.bestTranscription.segments)
                cont.resume(returning: captions)
            }
        }
    }

    /// Group word-level segments into ~3-second caption phrases for readability.
    private static func chunkSegments(_ segs: [SFTranscriptionSegment]) -> [Caption] {
        var captions: [Caption] = []
        var buffer: [SFTranscriptionSegment] = []
        let maxDur: TimeInterval = 3.5
        let maxChars = 80

        func flush() {
            guard !buffer.isEmpty else { return }
            let start = buffer.first!.timestamp
            let last = buffer.last!
            let end = last.timestamp + last.duration
            let text = buffer.map { $0.substring }
                .joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
            captions.append(Caption(
                id: "cap_\(captions.count)",
                startSec: start, endSec: end, text: text
            ))
            buffer.removeAll(keepingCapacity: true)
        }

        for seg in segs {
            buffer.append(seg)
            let runDur = (buffer.last!.timestamp + buffer.last!.duration) - buffer.first!.timestamp
            let runChars = buffer.reduce(0) { $0 + $1.substring.count }
            if runDur >= maxDur || runChars >= maxChars { flush() }
        }
        flush()
        return captions
    }
}
