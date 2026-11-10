import AppKit
import SwiftUI
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioCore

/// Recordings list: ⌘-click toggles, ⇧-click selects a range, select all;
/// plus a snapshot of the multi-select header for a design check.
final class LibrarySelectionTests: XCTestCase {
    @MainActor
    private func makeVM() -> (RecordingViewModel, [RecordingsLibrary.Entry]) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let vm = RecordingViewModel()
        let entries = (1...6).map { i in
            RecordingsLibrary.Entry(id: URL(fileURLWithPath: "/tmp/fake-\(i).basestudio"),
                                    displayName: "Recording-2026110\(i)", modifiedAt: Date(timeIntervalSince1970: Double(1_800_000_000 - i * 3600)),
                                    hasPolishedExport: false, isPlayable: true)
        }
        vm.library = entries
        return (vm, entries)
    }

    @MainActor
    func testCommandToggleShiftRangeAndSelectAll() {
        let (vm, e) = makeVM()
        vm.clickRecording(e[1], modifiers: .command)
        vm.clickRecording(e[3], modifiers: .command)
        XCTAssertEqual(vm.librarySelection, [e[1].id, e[3].id])
        vm.clickRecording(e[3], modifiers: .command)          // toggle off
        XCTAssertEqual(vm.librarySelection, [e[1].id])
        vm.clickRecording(e[1], modifiers: .command)          // off, anchor = e1
        vm.clickRecording(e[4], modifiers: .shift)            // range e1…e4
        XCTAssertEqual(vm.librarySelection, Set(e[1...4].map(\.id)))
        vm.selectAllRecordings()
        XCTAssertEqual(vm.librarySelection.count, 6)
        vm.clearRecordingSelection()
        XCTAssertTrue(vm.librarySelection.isEmpty)
    }

    @MainActor
    func testRenderMultiSelectList() throws {
        let (vm, e) = makeVM()
        vm.librarySelection = Set(e[1...3].map(\.id))
        let view = RecordingsListView(vm: vm).frame(height: 420).background(BS.Color.bgGradient).preferredColorScheme(.light)
        let data = try SnapshotProbeTests.renderPNG(view, size: CGSize(width: 248, height: 420))
        try data.write(to: URL(fileURLWithPath: "/tmp/recordings-multiselect.png"))
    }
}
