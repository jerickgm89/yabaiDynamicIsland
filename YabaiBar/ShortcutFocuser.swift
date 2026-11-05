import AppKit
import ApplicationServices

// Cambia de escritorio pulsando el atajo "Ir al escritorio N" de Mission Control tal como está configurado
// en Ajustes › Teclado › Atajos (en esta máquina, ⌥N), así que macOS hace su deslizamiento nativo.
// Necesita el permiso de Accesibilidad para enviar teclas. Con la firma ad-hoc, macOS lo olvida en cada
// compilación o reinstalación de la app.
@MainActor
final class ShortcutFocuser {
    struct Shortcut: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        /// Como lo escribe macOS, por ejemplo "⌥1"
        let label: String
    }

    enum Readiness: Equatable {
        case ready
        case noShortcut
        case needsPermission
    }

    private static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private var promptedForAccess = false

    /// El atajo de cada escritorio; los que no tienen atajo no aparecen
    func labels(for indices: [Int]) -> [Int: String] {
        let hotkeys = Self.currentHotkeys()
        var labels: [Int: String] = [:]
        for index in indices {
            labels[index] = Self.shortcut(forDesktop: index, in: hotkeys)?.label
        }
        return labels
    }

    func readiness(for index: Int) -> Readiness {
        guard Self.shortcut(forDesktop: index, in: Self.currentHotkeys()) != nil else { return .noShortcut }
        return AXIsProcessTrusted() ? .ready : .needsPermission
    }

    /// Añade YabaiBar a la lista de Accesibilidad si no está; macOS solo pregunta cuando la entrada es nueva.
    /// Si ya hay una entrada de otra compilación, macOS no pregunta y no la reconoce: a partir del segundo
    /// intento se abre la lista para quitarla con "−" (apagarla y encenderla no basta)
    func requestPermission() {
        // Literal en vez de kAXTrustedCheckOptionPrompt: esa global es una var no aislada en Swift 6
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if promptedForAccess { NSWorkspace.shared.open(Self.accessibilitySettings) }
        promptedForAccess = true
    }

    @discardableResult
    func focus(space index: Int) -> Bool {
        guard AXIsProcessTrusted(), let shortcut = Self.shortcut(forDesktop: index, in: Self.currentHotkeys()) else {
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: keyDown)
            event?.flags = shortcut.flags
            event?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// AppleSymbolicHotKeys de com.apple.symbolichotkeys. Se sincroniza antes de leer para ver los cambios hechos en
    /// Ajustes con la app abierta
    nonisolated static func currentHotkeys() -> [String: Any] {
        let domain = SymbolicHotKeysWriter.domain as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(SymbolicHotKeysWriter.key as CFString, domain) as? [String: Any] ?? [:]
    }

    /// Lee el atajo de AppleSymbolicHotKeys: los ids 118...126 son "Ir al escritorio 1...9" y
    /// `parameters` es [carácter, código de tecla, máscara de modificadores].
    nonisolated static func shortcut(forDesktop index: Int, in hotkeys: [String: Any]) -> Shortcut? {
        guard DesktopShortcuts.desktops.contains(index),
              let parameters = DesktopShortcuts.enabledParameters(hotkeys[DesktopShortcuts.id(forDesktop: index)])
        else { return nil }
        // La máscara usa los mismos bits que CGEventFlags (⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20)
        let flags = CGEventFlags(rawValue: UInt64(parameters[2]))
        return Shortcut(keyCode: CGKeyCode(parameters[1]), flags: flags, label: label(character: parameters[0], flags: flags))
    }

    // Símbolos en el orden en que los escribe macOS: ⌃ ⌥ ⇧ ⌘ y la tecla
    nonisolated static func label(character: Int, flags: CGEventFlags) -> String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        // 65535 significa que el atajo no tiene carácter
        if character < 0xFFFF, let scalar = UnicodeScalar(UInt32(character)) {
            text += String(Character(scalar)).uppercased()
        }
        return text
    }
}
