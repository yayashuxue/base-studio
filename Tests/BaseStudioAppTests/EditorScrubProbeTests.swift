import AppKit
import AVFoundation
import XCTest
@testable import BaseStudioApp

/// Manual probe (BS_EXISTING_BUNDLE): drag the playhead while playing and
/// while paused on a real take; the playhead, the player and the picture
/// must land on the new position.
final class EditorScrubProbeTests: XCTestCase {
    @MainActor
    func testScrubWhilePlayingAndPaused() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        editor.previewPlayer.isMuted = true
        editor.setPlayhead(10)
        editor.play()
        for _ in 0..<150 where editor.previewPlayer.timeControlStatus != .playing { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("SCRUB playing: playhead \(editor.playheadSec) player \(editor.previewPlayer.currentTime().seconds) drawsPicture \(editor.playerDrawsPicture)")
        // Drag while playing.
        for x in stride(from: 40.0, through: 80.0, by: 10) { editor.setPlayhead(x); try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let p1 = editor.playheadSec, pl1 = editor.previewPlayer.currentTime().seconds
        print("SCRUB after drag to 80 while playing: playhead \(p1) player \(pl1)")
        XCTAssertGreaterThan(p1, 79.5); XCTAssertLessThan(p1, 83)
        XCTAssertEqual(pl1, p1, accuracy: 0.3)
        // Drag while paused.
        editor.pause()
        for x in stride(from: 60.0, through: 30.0, by: -10) { editor.setPlayhead(x); try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        print("SCRUB after drag to 30 paused: playhead \(editor.playheadSec), still image \(String(describing: editor.renderedImage?.size))")
        XCTAssertEqual(editor.playheadSec, 30, accuracy: 0.01)
        XCTAssertNotNil(editor.renderedImage)
        // Play again from there: sound and picture start at 30.
        editor.play()
        for _ in 0..<150 where editor.previewPlayer.timeControlStatus != .playing { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)
        print("SCRUB resume: playhead \(editor.playheadSec) player \(editor.previewPlayer.currentTime().seconds)")
        XCTAssertGreaterThan(editor.playheadSec, 29.9); XCTAssertLessThan(editor.playheadSec, 32)
        editor.pause()
    }
}
