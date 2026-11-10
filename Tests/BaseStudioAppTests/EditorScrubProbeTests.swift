import AppKit
import AVFoundation
import XCTest
@testable import BaseStudioApp

/// Manual probe (BS_EXISTING_BUNDLE): drag the playhead while playing and
/// while paused on a real take; the playhead, the player and the picture
/// must land on the new position.
final class EditorScrubProbeTests: XCTestCase {
    /// Run the main run loop like the app does (timers, main-queue hops);
    /// Task.sleep in a test does not service AppKit timers reliably.
    @MainActor private func spin(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    func testScrubWhilePlayingAndPaused() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        editor.previewPlayer.isMuted = true
        editor.setPlayhead(10)
        editor.play()
        for _ in 0..<150 where editor.previewPlayer.timeControlStatus != .playing { await spin(0.02) }
        await spin(1.0)
        print("SCRUB playing: playhead \(editor.playheadSec) player \(editor.previewPlayer.currentTime().seconds) drawsPicture \(editor.playerDrawsPicture)")
        // Drag while playing.
        for x in stride(from: 40.0, through: 80.0, by: 10) { editor.setPlayhead(x); await spin(0.05) }
        await spin(1.5)
        let p1 = editor.playheadSec, pl1 = editor.previewPlayer.currentTime().seconds
        print("SCRUB after drag to 80 while playing: playhead \(p1) player \(pl1)")
        XCTAssertGreaterThan(p1, 79.5); XCTAssertLessThan(p1, 83)
        XCTAssertEqual(pl1, p1, accuracy: 0.3)
        // Seeking while playing, then pause: the still shows where it stopped.
        editor.pause()
        let stopAt = editor.playheadSec
        await spin(2.0)
        print("SCRUB pause after seeks: playhead \(stopAt), still at \(String(describing: editor.renderedImagePTS?.seconds)) scale \(editor.renderedImageScale)")
        XCTAssertEqual(editor.renderedImagePTS?.seconds ?? -1, stopAt, accuracy: 0.05)
        XCTAssertEqual(editor.renderedImageScale, 1)
        // Drag back and forth while paused.
        for x in [60.0, 20.0, 70.0, 45.0, 30.0] { editor.setPlayhead(x); await spin(0.05) }
        await spin(2.0)
        print("SCRUB after back-and-forth to 30 paused: playhead \(editor.playheadSec), still at \(String(describing: editor.renderedImagePTS?.seconds)) scale \(editor.renderedImageScale)")
        XCTAssertEqual(editor.playheadSec, 30, accuracy: 0.01)
        XCTAssertEqual(editor.renderedImagePTS?.seconds ?? -1, 30, accuracy: 0.01, "the still must be the frame at 30 s, not an earlier drag position")
        XCTAssertEqual(editor.renderedImageScale, 1, "the resting frame is full quality")
        // Play again from there: sound and picture start at 30.
        editor.play()
        for _ in 0..<150 where editor.previewPlayer.timeControlStatus != .playing { await spin(0.02) }
        await spin(0.5)
        print("SCRUB resume: playhead \(editor.playheadSec) player \(editor.previewPlayer.currentTime().seconds)")
        XCTAssertGreaterThan(editor.playheadSec, 29.9); XCTAssertLessThan(editor.playheadSec, 32)
        // Drag then play immediately: no full-size still fires during play.
        editor.pause()
        editor.setPlayhead(50)
        editor.play()
        let scaleBefore = editor.renderedImageScale
        await spin(0.6)
        XCTAssertEqual(editor.renderedImageScale, scaleBefore, "settle render fired while playing")
        // …and the player started from the drag target, not an older seek.
        print("SCRUB drag-then-play: player \(editor.previewPlayer.currentTime().seconds)")
        XCTAssertGreaterThan(editor.previewPlayer.currentTime().seconds, 49.9)
        XCTAssertLessThan(editor.previewPlayer.currentTime().seconds, 51.5)
        // Rapid drags then play at once.
        editor.pause()
        for x in [20.0, 90.0, 60.0] { editor.setPlayhead(x) }
        editor.play()
        await spin(1.0)
        print("SCRUB rapid drags then play: player \(editor.previewPlayer.currentTime().seconds)")
        XCTAssertGreaterThan(editor.previewPlayer.currentTime().seconds, 59.9)
        XCTAssertLessThan(editor.previewPlayer.currentTime().seconds, 61.5)
        editor.pause()
    }
}
