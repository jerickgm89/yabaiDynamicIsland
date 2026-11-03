import AppKit
import Carbon.HIToolbox
import SwiftUI

// La ventana de ajustes, que se abre desde el menú. La app no sale en el Dock: al abrirla se activa, para que la
// ventana quede delante y reciba el teclado (el grabador del atajo lo necesita), y al cerrarla se desactiva.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
        window.title = "Ajustes de YabaiBar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // Vuelve al frente la app que se estaba usando. Una grabación a medias se cancela, para que el atajo vuelva a funcionar
    func windowWillClose(_ notification: Notification) {
        settings.isRecordingShortcut = false
        NSApp.deactivate()
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Velocidad de las alas", selection: $settings.switchSpeed) {
                    ForEach(SwitchSpeed.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Al cambiar de escritorio")
            } footer: {
                Text("Lo que tardan las alas en recogerse hacia el notch y volver a salir. El deslizamiento del escritorio es de macOS y no cambia.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Atajo") { ShortcutRecorder(settings: settings) }
                Toggle("Ocultar sola", isOn: $settings.autoHide)
                Stepper(value: $settings.autoHideDelay, in: AppSettings.autoHideDelays) {
                    Text("Al cabo de \(settings.autoHideDelay) s")
                }
                .disabled(!settings.autoHide)
            } header: {
                Text("Abrir desde cualquier app")
            } footer: {
                Text("3 o 4 dedos hacia abajo en el trackpad, o el atajo, abren y cierran la isla. Si llevas el puntero a la isla, ya no se oculta sola: se cierra al sacarlo.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

// Graba un atajo nuevo: al pulsarlo escucha la siguiente tecla. Esc cancela y ⌫ deja la isla sin atajo
private struct ShortcutRecorder: View {
    @Bindable var settings: AppSettings
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                if !settings.isRecordingShortcut, settings.toggleShortcut != .defaultToggle {
                    Button("Restablecer") { settings.toggleShortcut = .defaultToggle }
                }
                Button(action: toggleRecording) {
                    Text(title).frame(minWidth: 120)
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(rejected || settings.shortcutError != nil ? .red : .secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var title: String {
        if settings.isRecordingShortcut { return "Pulsa el atajo…" }
        return settings.toggleShortcut?.label ?? "Sin atajo"
    }

    private var hint: String? {
        if rejected { return "Usa ⌘, ⌥ o ⌃ con otra tecla" }
        if settings.isRecordingShortcut { return "Esc cancela · ⌫ quita el atajo" }
        return settings.shortcutError
    }

    private func toggleRecording() {
        if settings.isRecordingShortcut { return stopRecording() }
        rejected = false
        settings.isRecordingShortcut = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let modifiers = Self.carbonModifiers(event.modifierFlags)
            let character = event.charactersIgnoringModifiers ?? ""
            // Si la grabación terminó al cerrar la ventana, el monitor deja pasar la tecla
            let recorded = MainActor.assumeIsolated { () -> Bool in
                guard settings.isRecordingShortcut else { return false }
                record(keyCode: keyCode, modifiers: modifiers, character: character)
                return true
            }
            // La tecla grabada no llega a la ventana
            return recorded ? nil : event
        }
    }

    private func record(keyCode: Int, modifiers: Int, character: String) {
        if modifiers == 0, keyCode == kVK_Escape { return stopRecording() }
        if modifiers == 0, keyCode == kVK_Delete {
            settings.toggleShortcut = nil
            return stopRecording()
        }
        guard let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: modifiers, character: character) else {
            rejected = true
            NSSound.beep()
            return
        }
        settings.toggleShortcut = shortcut
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        rejected = false
        settings.isRecordingShortcut = false
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        return modifiers
    }
}
