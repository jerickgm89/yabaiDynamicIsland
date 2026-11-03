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

    static func escape(action: @escaping @MainActor @Sendable () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: kVK_Escape, modifiers: 0, action: action)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
