import CoreGraphics
import Foundation
import Testing
@testable import YabaiBar

// Entradas de AppleSymbolicHotKeys como las guarda macOS: parameters = [carácter, código de tecla, modificadores]
private func hotkey(enabled: Bool = true, _ parameters: [Int]) -> [String: Any] {
    ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]
}

struct ShortcutFocuserTests {
    // "Ir al escritorio 1" es el id 118: ⌥1 es el carácter "1" (49), la tecla 18 y la máscara de ⌥ (1 << 19)
    @Test func readsTheOptionNumberShortcut() {
        let hotkeys: [String: Any] = ["118": hotkey([49, 18, 524_288])]
        let shortcut = ShortcutFocuser.shortcut(forDesktop: 1, in: hotkeys)
        #expect(shortcut == ShortcutFocuser.Shortcut(keyCode: 18, flags: .maskAlternate, label: "⌥1"))
    }

    @Test func ignoresDisabledMissingAndOutOfRangeDesktops() {
        let hotkeys: [String: Any] = ["122": hotkey(enabled: false, [53, 23, 524_288])]
        #expect(ShortcutFocuser.shortcut(forDesktop: 5, in: hotkeys) == nil)
        #expect(ShortcutFocuser.shortcut(forDesktop: 2, in: hotkeys) == nil)
        #expect(ShortcutFocuser.shortcut(forDesktop: 10, in: ["127": hotkey([48, 29, 524_288])]) == nil)
    }

    @Test func rejectsMalformedEntries() {
        let hotkeys: [String: Any] = ["119": ["enabled": true, "value": ["parameters": [50, 19]]]]
        #expect(ShortcutFocuser.shortcut(forDesktop: 2, in: hotkeys) == nil)
    }

    // ⌃⇧ con la tecla 3, en el orden de macOS; 65535 es un atajo sin carácter
    @Test func labelsFollowTheMacOSModifierOrder() {
        #expect(ShortcutFocuser.label(character: 51, flags: [.maskShift, .maskControl]) == "⌃⇧3")
        #expect(ShortcutFocuser.label(character: 65_535, flags: [.maskCommand, .maskAlternate]) == "⌥⌘")
    }
}
