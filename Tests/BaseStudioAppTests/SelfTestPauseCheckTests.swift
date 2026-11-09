import AVFoundation
import XCTest
@testable import BaseStudioApp

/// The pause self-test must count real samples (one timing entry can cover a
/// whole buffer) and report unreadable tracks as failures, not zeros.
final class SelfTestPauseCheckTests: XCTestCase {

    func testCountsEveryAudioPacketAndFailsOnMissingTracks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-count-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {   // AVAudioFile finishes the file when released
            let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            ])
            let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 48_000 * 3)!
            buf.frameLength = 48_000 * 3
            try file.write(from: buf)
        }

        // 1 s of 48 kHz AAC = 1024-sample packets → ~47 packets in (1, 2).
        let n = await SelfTest.count(url, .audio, 1.0, 2.0)
        XCTAssertGreaterThanOrEqual(n, 46)
        XCTAssertLessThanOrEqual(n, 49)
        let noVideo = await SelfTest.count(url, .video, 1.0, 2.0)
        XCTAssertEqual(noVideo, -1, "missing track must not read as 0")
        let noFile = await SelfTest.count(url.deletingLastPathComponent().appendingPathComponent("nope.m4a"), .audio, 0, 1)
        XCTAssertEqual(noFile, -1)
    }
}
