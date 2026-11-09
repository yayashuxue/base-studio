import AppKit
import Foundation

/// Persistent Base Studio item in the system menu bar.
/// Idle: compact icon that brings the app forward.
/// Recording: red icon + timer + Stop text; click stops immediately.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var elapsedTimer: Timer?
    private var startedAt: Date?

    var onStop: (() -> Void)?
    var onShowApp: (() -> Void)?

    func showIdle() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        startedAt = nil

        let item = ensureStatusItem()
        if let button = item.button {
            button.target = self
            button.action = #selector(itemAction(_:))
            button.image = NSImage(
                systemSymbolName: "video.circle.fill",
                accessibilityDescription: "Base Studio"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.contentTintColor = nil
            button.title = ""
            button.toolTip = "Base Studio — click to show"
        }
    }

    /// Shortcut shown in the tooltip, only when it is registered.
    var stopKey: String?

    func show() {
        startedAt = Date()

        let item = ensureStatusItem()
        if let button = item.button {
            button.target = self
            button.action = #selector(itemAction(_:))
            button.image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: "Recording"
            )
            button.image?.isTemplate = false
            button.imagePosition = .imageLeft
            button.contentTintColor = .systemRed
            button.font = .menuBarFont(ofSize: 0)
            button.title = " 0:00  Stop "
            button.toolTip = stopKey.map { "Click to stop recording  (\($0))" } ?? "Click to stop recording"
        }

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTitle() }
        }
    }

    func hide() {
        showIdle()
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        return item
    }

    private func tickTitle() {
        guard let startedAt, let button = statusItem?.button else { return }
        let elapsed = BS.Format.mmss(Date().timeIntervalSince(startedAt))
        button.title = " \(elapsed)  Stop "
    }

    @objc private func itemAction(_ sender: Any?) {
        if startedAt != nil {
            onStop?()
        } else {
            onShowApp?()
        }
    }
}
