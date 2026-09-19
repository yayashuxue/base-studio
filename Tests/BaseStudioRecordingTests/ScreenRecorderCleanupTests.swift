import ScreenCaptureKit
import XCTest
@testable import BaseStudioRecording

/// Failure-path / cleanup tests for ScreenRecorder's stream lifecycle, using a
/// throwing fake `ScreenStreamAdapter` so the rollback + teardown run WITHOUT
/// live ScreenCaptureKit capture (小o's requirement: the incident was an
/// untested lifecycle change; prove the cleanup). Covers add-output throw,
/// startCapture throw, stopCapture throw, output removal on teardown, and
/// re-usability after an error.
@available(macOS 13.0, *)
final class ScreenRecorderCleanupTests: XCTestCase {

    final class FakeAdapter: ScreenStreamAdapter {
        enum Fail { case none, addScreen, addAudio, start, stop }
        var failMode: Fail
        private(set) var added: [SCStreamOutputType] = []
        private(set) var removed: [SCStreamOutputType] = []
        private(set) var startCalled = false
        private(set) var stopCalled = false
        struct FakeError: Error {}
        init(_ f: Fail = .none) { failMode = f }

        func addOutput(_ output: SCStreamOutput, type: SCStreamOutputType, queue: DispatchQueue) throws {
            if (failMode == .addScreen && type == .screen) || (failMode == .addAudio && type == .audio) {
                throw FakeError()
            }
            added.append(type)
        }
        func removeOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws {
            removed.append(type)
        }
        func startCapture() async throws { startCalled = true; if failMode == .start { throw FakeError() } }
        func stopCapture() async throws { stopCalled = true; if failMode == .stop { throw FakeError() } }
    }

    func testAddOutputThrowStopsBeforeStartCapture() async {
        let rec = ScreenRecorder(captureSystemAudio: true)
        let fake = FakeAdapter(.addScreen)
        do {
            try await rec.attachAndStart(adapter: fake, captureAudio: true)
            XCTFail("expected addOutput to throw")
        } catch {}
        XCTAssertFalse(fake.startCalled, "must not start capture after an add-output failure")
        XCTAssertEqual(fake.added.count, 0, "screen output add failed, nothing recorded as added")
    }

    func testStartCaptureThrowLeavesTeardownRemovingEveryAttachedOutput() async {
        let rec = ScreenRecorder(captureSystemAudio: true)
        let fake = FakeAdapter(.start)
        do {
            try await rec.attachAndStart(adapter: fake, captureAudio: true)
            XCTFail("expected startCapture to throw")
        } catch {}
        XCTAssertTrue(fake.startCalled)
        XCTAssertEqual(fake.added, [.screen, .audio], "both outputs attached before start")
        // Teardown must remove exactly what was attached + stop the stream.
        await rec.teardownStream(adapter: fake)
        XCTAssertEqual(Set(fake.removed), Set([.screen, .audio]))
        XCTAssertTrue(fake.stopCalled)
        XCTAssertEqual(rec.attachedOutputCount, 0)
    }

    func testStopCaptureThrowInTeardownIsBestEffortAndStillRemovesOutputs() async {
        let rec = ScreenRecorder(captureSystemAudio: true)
        let fake = FakeAdapter(.none)
        try? await rec.attachAndStart(adapter: fake, captureAudio: true)
        fake.failMode = .stop
        // Must not throw / crash — teardown swallows a stopCapture failure.
        await rec.teardownStream(adapter: fake)
        XCTAssertEqual(Set(fake.removed), Set([.screen, .audio]),
                       "outputs removed even when stopCapture throws (so no late frame appends)")
        XCTAssertTrue(fake.stopCalled)
    }

    func testResetHandlesReturnsToReusableNonRunningState() async {
        let rec = ScreenRecorder(captureSystemAudio: true)
        let fake = FakeAdapter(.start)
        do { try await rec.attachAndStart(adapter: fake, captureAudio: true) } catch {}
        await rec.teardownStream(adapter: fake)
        rec.resetHandles()
        // After an errored start + teardown, the recorder is fully clean and can
        // start again (no leaked adapter / stuck isRunning / dangling outputs).
        XCTAssertFalse(rec.isCapturing)
        XCTAssertFalse(rec.hasStreamAdapter)
        XCTAssertEqual(rec.attachedOutputCount, 0)
    }

    func testScreenOnlyAttachesOnlyScreenOutput() async {
        let rec = ScreenRecorder(captureSystemAudio: false)
        let fake = FakeAdapter(.none)
        try? await rec.attachAndStart(adapter: fake, captureAudio: false)
        XCTAssertEqual(fake.added, [.screen], "no audio output when system audio is off")
        await rec.teardownStream(adapter: fake)
        XCTAssertEqual(fake.removed, [.screen])
    }
}
