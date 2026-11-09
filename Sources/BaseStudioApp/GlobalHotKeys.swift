import AppKit
import Carbon.HIToolbox

/// System-wide recording shortcuts via Carbon `RegisterEventHotKey`, which —
/// unlike an NSEvent global monitor — needs no Accessibility permission, so
/// the keys always work (a monitor without that permission silently did
/// nothing; the user believed the recording had stopped).
@MainActor
final class GlobalHotKeys {
    enum Action: UInt32 { case stop = 1, stopLegacy, pause, retake }

    /// (action, key code, modifiers). ⌥⇧ like Loom; ⌘⇧. kept for stop.
    static let bindings: [(Action, Int, Int)] = [
        (.stop, kVK_ANSI_S, optionKey | shiftKey),
        (.stopLegacy, kVK_ANSI_Period, cmdKey | shiftKey),
        (.pause, kVK_ANSI_P, optionKey | shiftKey),
        (.retake, kVK_ANSI_R, optionKey | shiftKey),
    ]

    var onAction: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let user, let action = GlobalHotKeys.Action(rawValue: id.id) else { return noErr }
            let keys = Unmanaged<GlobalHotKeys>.fromOpaque(user).takeUnretainedValue()
            Task { @MainActor in keys.onAction?(action) }
            return noErr
        }, 1, &spec, me, &handler)

        for (action, code, mods) in Self.bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4253_484B), id: action.rawValue) // 'BSHK'
            let status = RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
