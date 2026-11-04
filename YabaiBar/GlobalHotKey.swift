import Carbon.HIToolbox

// Un atajo de teclado global con RegisterEventHotKey de Carbon: llega aunque la app no esté activa, no pide
// permisos y la app de delante no lo recibe. Se quita al soltar el objeto.
final class GlobalHotKey {
    private static let signature: OSType = 0x5942_4152 // "YBAR"

    private let id: UInt32
    private let action: @MainActor @Sendable () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// `keyCode` es un kVK_… y `modifiers`, las máscaras de Carbon (optionKey, cmdKey…). nil si macOS no lo acepta,
    /// por ejemplo porque otra app ya tiene ese atajo
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor @Sendable () -> Void) {
        // Varios atajos comparten el mismo aviso de Carbon: cada uno reconoce el suyo por este id
        id = UInt32(keyCode << 16 | modifiers)
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            // Carbon avisa en el hilo principal
            let action = hotKey.action
            MainActor.assumeIsolated { action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard installed == noErr, registered == noErr else { return nil }
    }

    convenience init?(shortcut: HotKeyShortcut, action: @escaping @MainActor @Sendable () -> Void) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: action)
    }

    static func escape(action: @escaping @MainActor @Sendable () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: kVK_Escape, modifiers: 0, action: action)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// Lógica pura de un atajo global elegido por el usuario: qué combinaciones valen y cómo se escriben
struct HotKeyShortcut: Codable, Equatable {
    /// Un kVK_…
    let keyCode: Int
    /// Máscaras de Carbon: controlKey, optionKey, shiftKey y cmdKey
    let modifiers: Int
    /// Como lo escribe macOS, por ejemplo "⌥I"
    let label: String

    static let defaultToggle = HotKeyShortcut(keyCode: kVK_ANSI_I, modifiers: optionKey, label: "⌥I")
    /// Iniciar o pausar el Pomodoro. skhd usa ⇧⌥P, no ⌥P, y en el teclado US solo escribía "π"
    static let defaultPomodoro = HotKeyShortcut(keyCode: kVK_ANSI_P, modifiers: optionKey, label: "⌥P")

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Espacio", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// `character` es la tecla sin modificadores, como la da el teclado. nil si no vale como atajo global:
    /// Esc está reservado, y una tecla que no sea de función necesita ⌘, ⌥ o ⌃ (con solo ⇧ se escribiría una
    /// mayúscula en todas las apps)
    init?(keyCode: Int, modifiers: Int, character: String) {
        guard keyCode != kVK_Escape else { return nil }
        let key: String
        if let function = Self.functionKeys[keyCode] {
            key = function
        } else {
            guard modifiers & (cmdKey | optionKey | controlKey) != 0 else { return nil }
            key = Self.namedKeys[keyCode] ?? character.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        guard !key.isEmpty else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, label: Self.symbols(for: modifiers) + key)
    }

    // En el orden en que los escribe macOS: ⌃ ⌥ ⇧ ⌘
    private static func symbols(for modifiers: Int) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()
    }
}
