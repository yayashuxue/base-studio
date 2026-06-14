import AppKit
import Foundation

/// Always-visible Stop in the system menu bar. Shows `● 0:23 · Stop` text;
/// clicking anywhere on the item stops the recording immediately (no submenu).
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var hotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    var onStop: (() -> Void)?

    func show() {
        guard statusItem == nil else { return }
        installHotkey()
        startedAt = Date()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(stopAction(_:))
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
        statusItem = item

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTitle() }
        }
    }

    func hide() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        removeHotkey()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        startedAt = nil
    }

    private func tickTitle() {
        guard let startedAt, let button = statusItem?.button else { return }
        let elapsed = BS.Format.mmss(Date().timeIntervalSince(startedAt))
        button.title = " \(elapsed)  Stop "
    }

    @objc private func stopAction(_ sender: Any?) {
        onStop?()
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
