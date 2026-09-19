import XCTest
@testable import BaseStudioRecording

/// Headless-safe lifecycle guards. The rollback-on-failed-start and
/// queue-drain-on-stop paths themselves need a live SCStream (covered by the
/// signed-app --selftest-record gate), but the state guards that keep a failed
/// or never-started recorder from crashing on stop ARE unit-testable and are
/// what turns a leak into a clean, catchable error.
@available(macOS 13.0, *)
final class RecorderLifecycleTests: XCTestCase {

    func testScreenRecorderStopBeforeStartThrowsNotRunning() async {
        let r = ScreenRecorder(captureSystemAudio: false)
        do {
            _ = try await r.stop()
            XCTFail("stop() before start() should throw, not return")
        } catch let e as ScreenRecorderError {
            guard case .notRunning = e else {
                return XCTFail("expected .notRunning, got \(e)")
            }
        } catch {
            XCTFail("expected ScreenRecorderError.notRunning, got \(error)")
        }
    }

    func testWebcamRecorderStopBeforeStartIsCleanZeroFrames() async {
        // A never-started webcam recorder must report an honest zero-frame
        // result (which RecordingSession turns into a visible missing-track
        // diagnostic) rather than crash.
        let r = WebcamRecorder()
        let result = await r.stop()
        XCTAssertEqual(result.framesAppended, 0)
        XCTAssertEqual(result.firstPTS, .zero)
    }

    func testRecordingSessionStopBeforeStartThrowsNotRunning() async {
        let session = RecordingSession(options: .init(
            includeWebcam: false, includeSystemAudio: false, includeMic: false
        ))
        do {
            _ = try await session.stop()
            XCTFail("stop() before start() should throw")
        } catch let e as RecordingSessionError {
            guard case .notRunning = e else {
                return XCTFail("expected .notRunning, got \(e)")
            }
        } catch {
            XCTFail("expected RecordingSessionError.notRunning, got \(error)")
        }
    }
}
