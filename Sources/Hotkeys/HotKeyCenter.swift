import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than an `NSEvent` global monitor on purpose: a registered hot key
/// needs no Accessibility or Input Monitoring permission, and it consumes the
/// keystroke so the frontmost app doesn't also receive ⌘⇧1.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    /// Four-char signature identifying our hot keys to Carbon.
    private static let signature: OSType = 0x4856_4C53 // "HVLS"

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers hot-key events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }

    /// Registers `shortcut` under `id`, replacing whatever `id` had before. Returns
    /// false when another app already owns the combination.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }
}
