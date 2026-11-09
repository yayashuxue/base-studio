import XCTest
@testable import BaseStudioRecording

/// macOS "Stop Sharing" ends the SCStream without stop(): the app used to
/// stay in "recording" with nothing arriving and never close the bundle.
@available(macOS 13.0, *)
final class CaptureEndedTests: XCTestCase {

    func testStreamStopReachesTheSessionOwner() {
        let session = RecordingSession(options: .init(
            includeWebcam: false, includeSystemAudio: false, includeMic: false
        ))
        let fired = expectation(description: "owner told capture ended")
        session.onCaptureEnded = { error in
            XCTAssertEqual((error as NSError).code, -3817)
            fired.fulfill()
        }
        let userStopped = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3817,
                                  userInfo: [NSLocalizedDescriptionKey: "The user stopped the stream"])
        session.screenRecorderForTests.handleStreamStopped(userStopped)
        wait(for: [fired], timeout: 1)
    }
}
