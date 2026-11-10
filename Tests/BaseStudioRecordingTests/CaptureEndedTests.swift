import ScreenCaptureKit
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

/// stop() may excuse a stopCapture failure only in the known case.
@available(macOS 13.0, *)
final class ExpectedStopFailureTests: XCTestCase {
    func testOnlyAlreadyStoppedAfterTheStreamStoppedIsExcused() {
        let already = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.attemptToStopStreamState.rawValue)
        let other = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue)
        let foreign = NSError(domain: NSOSStatusErrorDomain, code: SCStreamError.Code.attemptToStopStreamState.rawValue)
        XCTAssertTrue(ScreenRecorder.isExpectedStopFailure(already, streamAlreadyStopped: true))
        XCTAssertFalse(ScreenRecorder.isExpectedStopFailure(already, streamAlreadyStopped: false),
                       "without the stream's own stop report it's a real failure")
        XCTAssertFalse(ScreenRecorder.isExpectedStopFailure(other, streamAlreadyStopped: true),
                       "a different SCK error must not hide behind the stream stop")
        XCTAssertFalse(ScreenRecorder.isExpectedStopFailure(foreign, streamAlreadyStopped: true))
    }
}
