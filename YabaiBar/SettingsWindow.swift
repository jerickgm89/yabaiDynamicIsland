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

// Tres pestañas: lo general de la isla, la música y el Pomodoro. Cada una se desplaza si no cabe
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            music.tabItem { Label("Música", systemImage: "music.note") }
            pomodoro.tabItem { Label("Pomodoro", systemImage: "timer") }
        }
        .frame(width: 480, height: 520)
    }

    private var general: some View {
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
                Toggle("Al pasar el puntero", isOn: $settings.openOnHover)
                LabeledContent("Atajo") { ShortcutRecorder(settings: settings) }
                Toggle("Ocultar sola", isOn: $settings.autoHide)
                Stepper(value: $settings.autoHideDelay, in: AppSettings.autoHideDelays) {
                    Text("Al cabo de \(settings.autoHideDelay) s")
                }
                .disabled(!settings.autoHide)
            } header: {
                Text("Abrir la isla")
            } footer: {
                Text("3 o 4 dedos hacia abajo en el trackpad, o el atajo, abren y cierran la isla desde cualquier app. Abierta así, si llevas el puntero a la isla ya no se oculta sola: se cierra al sacarlo.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Batería y cargador", isOn: $settings.batteryAlerts)
                Toggle("Botón de mantener despierto", isOn: $settings.keepAwakeButton)
            } header: {
                Text("Actividades")
            } footer: {
                Text("Avisos al enchufar o desenchufar el cargador y al bajar del 20 % y del 10 %, y un sol en la isla abierta que impide que el Mac se duerma hasta que lo apagues.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var music: some View {
        Form {
            Section {
                Toggle("Mostrar lo que suena", isOn: $settings.showNowPlaying)
                Group {
                    Picker("De", selection: $settings.nowPlayingSource) {
                        ForEach(NowPlayingSource.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Barras en la isla cerrada", isOn: $settings.showMusicBars)
                    Toggle("Avisar al cambiar de canción", isOn: $settings.announceTracks)
                }
                .disabled(!settings.showNowPlaying)
            } header: {
                Text("Música")
            } footer: {
                Text("Con la isla abierta, la canción, la carátula y los botones; dos dedos de lado sobre ella cambian de canción. Lo lee del «Ahora suena» de macOS: no se envía nada a internet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var pomodoro: some View {
        Form {
            Section {
                Toggle("Mostrar el Pomodoro", isOn: $settings.showPomodoro)
                Toggle("Anillo en la isla cerrada", isOn: $settings.showPomodoroRing)
                    .disabled(!settings.showPomodoro)
            } footer: {
                Text("Un temporizador en la esquina izquierda de la isla abierta y, mientras corre, una franja con la cuenta atrás y los botones. En la isla cerrada, un anillo de progreso y un aviso al cambiar de fase. Apagarlo termina la sesión.")
                    .foregroundStyle(.secondary)
            }

            Section("Tiempos") {
                Picker("Preset", selection: $settings.pomodoroPreset) {
                    ForEach(PomodoroPreset.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $settings.pomodoroFocusMinutes, in: AppSettings.focusMinutes, step: 5) {
                    Text("Foco: \(settings.pomodoroFocusMinutes) min")
                }
                Stepper(value: $settings.pomodoroShortBreakMinutes, in: AppSettings.shortBreakMinutes) {
                    Text("Descanso corto: \(settings.pomodoroShortBreakMinutes) min")
                }
                Stepper(value: $settings.pomodoroLongBreakMinutes, in: AppSettings.longBreakMinutes, step: 5) {
                    Text("Descanso largo: \(settings.pomodoroLongBreakMinutes) min")
                }
                Stepper(value: $settings.pomodoroRounds, in: AppSettings.pomodoroRoundsRange) {
                    Text("Descanso largo cada \(settings.pomodoroRounds) focos")
                }
            }
            .disabled(!settings.showPomodoro)

            Section {
                Toggle("Empezar los descansos solos", isOn: $settings.pomodoroAutoStartBreaks)
                Toggle("Empezar el foco solo tras el descanso", isOn: $settings.pomodoroAutoStartFocus)
                Picker("Avisar antes de terminar", selection: $settings.pomodoroWarning) {
                    ForEach(AppSettings.pomodoroWarnings, id: \.self) { seconds in
                        Text(seconds == 0 ? "No" : "\(seconds) s").tag(seconds)
                    }
                }
                Stepper(value: $settings.pomodoroDailyGoal, in: AppSettings.dailyGoals) {
                    Text("Objetivo del día: \(settings.pomodoroDailyGoal) pomodoros")
                }
            } header: {
                Text("Sesión")
            } footer: {
                Text("Los cambios de tiempo valen desde la siguiente fase. Si cambias un tiempo a mano, el preset pasa a «Personalizado».")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.showPomodoro)

            Section {
                Toggle("Sonidos", isOn: $settings.pomodoroSound)
                Toggle("Bajar la música en el aviso", isOn: $settings.pomodoroDuckMusic)
                Stepper(value: $settings.pomodoroDuckLevel, in: AppSettings.duckLevels, step: 5) {
                    Text("Hasta el \(settings.pomodoroDuckLevel) % de tu volumen")
                }
                .disabled(!settings.pomodoroDuckMusic)
            } header: {
                Text("Avisos")
            } footer: {
                Text("En el aviso suena una nota de kalimba y, si suena música, el volumen baja hasta el final. Al terminar el foco suena un cuenco y al terminar el descanso, dos notas; la música vuelve a tu volumen. Si tocas el volumen mientras está bajado, se queda como lo dejes.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.showPomodoro)
        }
        .formStyle(.grouped)
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
