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
    private var hotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    var onStop: (() -> Void)?
    var onShowApp: (() -> Void)?

    func showIdle() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        removeHotkey()
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

    func show() {
        installHotkey()
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
            button.toolTip = "Click to stop recording  (⌘⇧.)"
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

    // MARK: - hotkey ⌘⇧.

    private func installHotkey() {
        let mask: NSEvent.ModifierFlags = [.command, .shift]
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == mask,
                  event.charactersIgnoringModifiers == "." else { return }
            Task { @MainActor in self?.onStop?() }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == mask,
                  event.charactersIgnoringModifiers == "." else { return event }
            Task { @MainActor in self?.onStop?() }
            return nil
        }
    }
    private func removeHotkey() {
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localHotkeyMonitor { NSEvent.removeMonitor(m) }
        hotkeyMonitor = nil; localHotkeyMonitor = nil
    }
}
