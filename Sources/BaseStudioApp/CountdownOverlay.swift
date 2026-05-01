import AppKit
import Foundation

/// Borderless full-screen panel showing a 3-2-1 countdown before capture begins.
/// Sits above all windows and ignores mouse events. Calls `onDone` when finished;
/// caller is responsible for hiding the main window before starting capture.
@MainActor
final class CountdownOverlay {
    private var window: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var remaining: Int = 3

    func run(seconds: Int = 3, onDone: @escaping () -> Void) {
        remaining = seconds
        guard let screen = NSScreen.main else { onDone(); return }
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let dim = NSView(frame: screen.frame)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        let label = NSTextField(labelWithString: "\(remaining)")
        label.font = .systemFont(ofSize: 240, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
        ])
        panel.contentView = dim
        panel.orderFrontRegardless()
        self.window = panel
        self.label = label

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.remaining -= 1
                if self.remaining <= 0 {
                    self.timer?.invalidate(); self.timer = nil
                    self.window?.orderOut(nil); self.window = nil
                    onDone()
                } else {
                    self.label?.stringValue = "\(self.remaining)"
                }
            }
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil
    }
}
