import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, press a key combination, done. Esc cancels; a combination without ⌘, ⌃ or ⌥
/// is ignored because it would swallow ordinary typing system-wide.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let defaultShortcut: Shortcut
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Keycap(recording ? "Press keys" : shortcut.label, width: 84, listening: recording)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording ? "Press the new shortcut" : shortcut.label)

            // Always holds its place, so a changed shortcut doesn't shift its cap out of
            // line with the others.
            let changed = shortcut != defaultShortcut && !recording
            Button {
                shortcut = defaultShortcut
            } label: {
                Image(systemName: "arrow.counterclockwise").foregroundStyle(Color.accent)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help("Reset to \(defaultShortcut.label)")
            .accessibilityLabel("Reset to \(defaultShortcut.label)")
            .opacity(changed ? 1 : 0)
            .disabled(!changed)
            .accessibilityHidden(!changed)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
            shortcut = Shortcut(keyCode: UInt32(event.keyCode),
                                modifiers: Self.carbonModifiers(flags),
                                key: Self.keyName(event.keyCode))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            onRecordingChange(false)
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        return UInt32(mask)
    }

    /// The key's printed name on the current keyboard layout, without modifiers —
    /// so ⇧1 shows as "1", not "!", and an AZERTY user sees their own key.
    static func keyName(_ keyCode: UInt16) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
}

extension Shortcut {
    /// The combination as a menu shows it, right-aligned in the item like every other
    /// shortcut, rather than written into the title; nil for a key no menu can show.
    var menuShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        if let special = Self.menuKeys[Int(keyCode)] {
            equivalent = special
        } else if let function = Self.functionKeys.firstIndex(of: Int(keyCode)),
                  let scalar = UnicodeScalar(NSF1FunctionKey + function) {
            equivalent = KeyEquivalent(Character(scalar))
        } else if key.count == 1, let character = key.lowercased().first {
            equivalent = KeyEquivalent(character)
        } else {
            return nil
        }
        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }

    private static let menuKeys: [Int: KeyEquivalent] = [
        kVK_Space: .space, kVK_Return: .return, kVK_Tab: .tab, kVK_Delete: .delete,
        kVK_ForwardDelete: .deleteForward, kVK_LeftArrow: .leftArrow, kVK_RightArrow: .rightArrow,
        kVK_UpArrow: .upArrow, kVK_DownArrow: .downArrow, kVK_Home: .home, kVK_End: .end,
        kVK_PageUp: .pageUp, kVK_PageDown: .pageDown, kVK_Escape: .escape,
    ]

    /// F1 to F20 in order: their key codes aren't.
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}
