import AppKit

// Menú de la app, que abre cualquier clic sobre la isla. Se rehace cada vez que se abre, para
// mostrar el error de yabai y el estado de inicio al arrancar.
@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let store: SpacesStore
    private let launchAtLogin: LaunchAtLogin
    private let settingsWindow: SettingsWindow
    private let welcomeWindow: WelcomeWindow
    private let pomodoro: PomodoroStore
    private let settings: AppSettings
    private let maintenance: YabaiMaintenance

    init(
        store: SpacesStore, launchAtLogin: LaunchAtLogin, settingsWindow: SettingsWindow, welcomeWindow: WelcomeWindow,
        pomodoro: PomodoroStore, settings: AppSettings, maintenance: YabaiMaintenance
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.settingsWindow = settingsWindow
        self.welcomeWindow = welcomeWindow
        self.pomodoro = pomodoro
        self.settings = settings
        self.maintenance = maintenance
        super.init()
        menu.delegate = self
    }

    private func isNotInstalled(_ error: YabaiError) -> Bool {
        if case .notInstalled = error { return true }
        return false
    }

    @objc private func restartYabai() {
        maintenance.restart()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let error = store.lastError {
            // Sin acción: el menú lo muestra deshabilitado, como un aviso
            menu.addItem(NSMenuItem(title: error.userMessage, action: nil, keyEquivalent: ""))
            // Si yabai está instalado pero no responde, reiniciarlo (con confirmación) es lo que suele arreglarlo
            if !isNotInstalled(error) {
                let restart = NSMenuItem(title: "Reiniciar yabai…", action: #selector(restartYabai), keyEquivalent: "")
                restart.target = self
                menu.addItem(restart)
            }
            menu.addItem(.separator())
        }

        if settings.showPomodoro {
            let timer = pomodoro.timer
            let title = switch timer.state {
            case .stopped: "Iniciar Pomodoro"
            case .ready: timer.phase.isBreak ? "Empezar el descanso" : "Empezar el foco"
            case .running: "Pausar Pomodoro"
            case .paused: "Reanudar Pomodoro"
            }
            let toggle = NSMenuItem(title: title, action: #selector(togglePomodoro), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            if timer.isActive {
                let stop = NSMenuItem(title: "Terminar Pomodoro", action: #selector(stopPomodoro), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refrescar", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let available = launchAtLogin.isAvailable
        let login = NSMenuItem(
            title: available ? "Iniciar al arrancar" : "Iniciar al arrancar (instálala en /Applications)",
            action: available ? #selector(toggleLaunchAtLogin) : nil,
            keyEquivalent: ""
        )
        login.target = self
        login.state = available && launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        let settings = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let welcome = NSMenuItem(title: "Primeros pasos…", action: #selector(openWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func refreshFromMenu() {
        store.requestRefresh()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openWelcome() {
        welcomeWindow.show()
    }

    @objc private func togglePomodoro() {
        pomodoro.toggle()
    }

    @objc private func stopPomodoro() {
        pomodoro.stop()
    }
}

// Texto para el menú cuando yabai falla
extension YabaiError {
    var userMessage: String {
        switch self {
        case .notInstalled(let path): "No se encuentra yabai en \(path)"
        case .notRunning: "yabai no está en marcha"
        case .timedOut: "yabai no respondió a tiempo"
        case .commandFailed(_, let stderr) where stderr.isEmpty: "yabai devolvió un error"
        case .commandFailed(_, let stderr): "yabai: \(stderr.prefix(80))"
        case .decoding: "No se entendió la respuesta de yabai"
        }
    }
}
