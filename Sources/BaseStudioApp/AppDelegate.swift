import AppKit
import Foundation

/// Holds a weak handle to the recording VM so the Dock menu (and any other
/// app-wide entry points) can stop a recording even when the main window is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let shared = AppDelegate()
    weak var stopHandler: StopHandler?
    weak var editorActions: EditorActions?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force regular GUI app behavior so we always get a Dock icon, even when
        // launched from `swift run` (SPM binaries default to accessory mode).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Local signed-app E2E gate: when launched with --selftest-record, drive
        // the real record→stop→reopen→export flow and exit with a JSON report.
        if #available(macOS 13.0, *) { SelfTest.runIfRequested() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: stopHandler?.isRecording == true ? "Stop Recording" : "Not Recording",
            action: #selector(stopFromDock),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = stopHandler?.isRecording == true
        menu.addItem(item)
        return menu
    }

    @objc private func stopFromDock() {
        stopHandler?.stopRecording()
    }
}

@MainActor
protocol StopHandler: AnyObject {
    var isRecording: Bool { get }
    func stopRecording()
}

@MainActor
protocol EditorActions: AnyObject {
    func togglePlayPause()
    func deleteSelectedRegion()
    func export()
    func undo()
    func redo()
    func stepBackward(seconds: Double)
    func stepForward(seconds: Double)
    func gotoStart()
    func gotoEnd()
}
