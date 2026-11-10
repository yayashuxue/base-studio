import XCTest
@testable import BaseStudioApp

/// Picture must follow sound: with a soundtrack, the playhead does not move
/// before the sound is ready, and holds while the player buffers.
@MainActor
final class PreviewClockTests: XCTestCase {

    final class FakeAudio: PreviewAudioOutput {
        var prepareDelay: UInt64 = 0
        /// When true, prepare() waits until the test calls release() — no
        /// timing race with a loaded machine.
        var gated = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        func release() { released = true; waiter?.resume(); waiter = nil }
        var hasAudio = true
        var started: Double?
        var currentSeconds: Double = 0
        var endSeconds: Double = 10
        func prepare() async -> Bool {
            if gated && !released { await withCheckedContinuation { waiter = $0 } }
            if prepareDelay > 0 { try? await Task.sleep(nanoseconds: prepareDelay) }
            return hasAudio
        }
        var startSucceeds = true
        func start(at sec: Double) async -> Bool { started = sec; currentSeconds = sec; return startSucceeds }
        func pause() {}
        func seek(to sec: Double) { currentSeconds = sec }
    }

    func testSlowAudioPreparationHoldsThePicture() async throws {
        // A 3 s take whose sound takes 4 s to prepare: the old code ran the
        // picture to the end before any sound started.
        // Preparation is held open by the test (not timed): flaked once
        // under load when a 300 ms sleep overshot a 400 ms preparation.
        let audio = FakeAudio()
        audio.gated = true
        let clock = PreviewClock(output: audio, interval: 0.02)
        var ticks: [Double] = []
        clock.onTick = { sec, _ in ticks.append(sec) }
        clock.play(from: 1.0, duration: 3.0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ticks.isEmpty, "playhead moved before the sound was ready: \(ticks)")
        XCTAssertNil(audio.started)

        audio.release()
        // Wait (bounded) for the sound to start and a couple of ticks.
        for _ in 0..<150 where audio.started == nil || ticks.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(audio.started, 1.0, "sound must start where the playhead was")
        // Player is buffering (its time does not advance): picture holds.
        let held = ticks.count
        XCTAssertGreaterThan(held, 0)
        XCTAssertTrue(ticks.allSatisfy { $0 == 1.0 }, "picture drifted while sound was buffering: \(ticks)")

        // Sound moves → picture follows its clock exactly.
        audio.currentSeconds = 1.5
        clock.tick()
        XCTAssertEqual(ticks.last, 1.5)
        clock.pause()
    }

    func testNoSoundFallsBackToTimer() async throws {
        let audio = FakeAudio()
        audio.hasAudio = false
        let clock = PreviewClock(output: audio, interval: 0.02)
        var last = 0.0
        clock.onTick = { sec, _ in last = sec }
        clock.play(from: 0, duration: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        clock.pause()
        XCTAssertNil(audio.started)
        XCTAssertGreaterThan(last, 0.1, "silent take must still play")
    }

    func testPastEndOfSoundTimerFinishesTheTake() async throws {
        // Sound shorter than the picture: after it ends the timer carries on
        // and the take ends.
        let audio = FakeAudio()
        audio.endSeconds = 0.5
        let clock = PreviewClock(output: audio, interval: 0.02)
        var ended = false
        clock.onTick = { _, e in if e { ended = true } }
        clock.play(from: 0, duration: 0.8)
        try await Task.sleep(nanoseconds: 100_000_000)
        audio.currentSeconds = 0.5
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(ended)
        XCTAssertFalse(clock.isRunning)
    }

    func testStartFailureFallsBackToTimer() async throws {
        // Player can't start (seek never finished): the clock must not hang
        // on it — it runs on its own timer.
        let audio = FakeAudio()
        audio.startSucceeds = false
        let clock = PreviewClock(output: audio, interval: 0.02)
        var last = 0.0
        clock.onTick = { sec, _ in last = sec }
        clock.play(from: 0, duration: 5)
        try await Task.sleep(nanoseconds: 400_000_000)
        clock.pause()
        XCTAssertGreaterThan(last, 0.1, "playback hung on a failed start")
    }

    func testPauseDuringPreparationNeverStartsSound() async throws {
        let audio = FakeAudio()
        audio.prepareDelay = 200_000_000
        let clock = PreviewClock(output: audio, interval: 0.02)
        clock.play(from: 0, duration: 3)
        clock.pause()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(audio.started)
    }
}
