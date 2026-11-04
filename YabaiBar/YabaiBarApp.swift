import SwiftUI
import notify
import os

@main
struct YabaiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// Raíz de composición: crea una sola instancia de cada pieza, las conecta y recibe los avisos
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SpacesStore?
    private var menu: AppMenu?
    private var island: IslandController?
    private var settings: AppSettings?
    private var media: NowPlayingStore?
    private var battery: BatteryMonitor?
    private var pomodoro: PomodoroStore?
    private var pomodoroCue: PomodoroCue?
    private var toggleKey: GlobalHotKey?
    private var pomodoroKey: GlobalHotKey?
    private var trackpad: TrackpadMonitor?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshToken: Int32 = NOTIFY_TOKEN_INVALID
    private var terminationSignal: DispatchSourceSignal?

    // Las señales de yabai y los atajos de skhd avisan con `notifyutil -p com.jerickdev.yabaibar.refresh`.
    // La notificación llega a la instancia que está corriendo; una URL pasaría por LaunchServices,
    // que con dos copias de la app (la de build/ y la de /Applications) abría la otra
    static let refreshNotificationName = "com.jerickdev.yabaibar.refresh"

    // Lo que macOS avisa por sí solo; ventanas y espacios de yabai llegan por la notificación de refresco
    private static let refreshNotifications: [Notification.Name] = [
        NSWorkspace.activeSpaceDidChangeNotification,
        NSWorkspace.didActivateApplicationNotification,
        NSWorkspace.didLaunchApplicationNotification,
        NSWorkspace.didTerminateApplicationNotification,
        NSWorkspace.didHideApplicationNotification,
        NSWorkspace.didUnhideApplicationNotification,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let yabai = YabaiClient()
        let store = SpacesStore(yabai: yabai)
        self.store = store
        let settings = AppSettings()
        self.settings = settings
        let pomodoro = PomodoroStore(settings: settings)
        self.pomodoro = pomodoro
        let menu = AppMenu(
            store: store, launchAtLogin: LaunchAtLogin(), settingsWindow: SettingsWindow(settings: settings),
            pomodoro: pomodoro, settings: settings
        )
        self.menu = menu
        // En los tests la app hace de host y xcodebuild la cierra sin avisar (sin SIGTERM): el adaptador de música
        // quedaría huérfano en cada pasada, así que ahí no se arranca
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let media = NowPlayingStore(adapter: isTestHost ? nil : MediaRemoteAdapter(), settings: settings)
        self.media = media
        let island = IslandController(
            store: store, icons: AppIcons(), menu: menu, focuser: ShortcutFocuser(), settings: settings, media: media,
            keepAwake: KeepAwake(), pomodoro: pomodoro
        )
        self.island = island
        battery = BatteryMonitor { state in island.batteryChanged(state) }
        // Cada evento del Pomodoro: el aviso de la isla, y el sonido y la música
        let cue = PomodoroCue(settings: settings, media: media, pomodoro: pomodoro, ducker: VolumeDucker(), player: CuePlayer())
        pomodoroCue = cue
        pomodoro.onEvent = { event in
            island.pomodoroEvent(event)
            cue.handle(event)
        }

        // Abrir la isla desde cualquier app, sin llevar el puntero: el atajo de los ajustes (⌥I) o 3 o 4 dedos hacia abajo
        observeShortcuts()
        trackpad = TrackpadMonitor {
            Logger.app.info("Gesto: 3 o 4 dedos hacia abajo")
            island.toggle()
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = Self.refreshNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Logger.app.info("Aviso: \(name.rawValue, privacy: .public)")
                    // Al cambiar de escritorio la isla recoge las alas al momento, sin esperar a yabai
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        self?.island?.spaceDidChange()
                    }
                    store.requestRefresh()
                }
            }
        }
        notify_register_dispatch(Self.refreshNotificationName, &refreshToken, .main) { _ in
            MainActor.assumeIsolated {
                Logger.app.info("Aviso: notificación de refresco")
                store.requestRefresh()
            }
        }
        store.requestRefresh()
        handleTerminationSignal()
    }

    // `kill`, `pkill` y yb.sh mandan SIGTERM, que por defecto cierra la app sin pasar por applicationWillTerminate
    // y deja vivo el adaptador de música. La señal se convierte en un cierre normal, como "Salir"
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Logger.app.info("SIGTERM: cerrando como con Salir")
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        media?.shutDown()
        // Si se cierra con la música bajada por el Pomodoro, el volumen vuelve
        pomodoroCue?.restoreNow()
    }

    // Registra los atajos de los ajustes (abrir la isla y el Pomodoro) y los vuelve a registrar cada vez que
    // cambian. Mientras se graba uno nuevo, ninguno: Carbon se quedaría la tecla antes que la ventana de ajustes
    private func observeShortcuts() {
        guard let settings else { return }
        withObservationTracking {
            // Primero se sueltan los anteriores: registrar dos veces la misma combinación falla
            toggleKey = nil
            pomodoroKey = nil
            var toggleError: String?
            var pomodoroError: String?
            if !settings.isRecordingShortcut {
                if let shortcut = settings.toggleShortcut {
                    toggleKey = register(shortcut) { [weak self] in self?.island?.toggle() }
                    if toggleKey == nil { toggleError = Self.unavailable(shortcut) }
                }
                if settings.showPomodoro, let shortcut = settings.pomodoroShortcut {
                    if shortcut == settings.toggleShortcut {
                        pomodoroError = "Es el mismo atajo que abre la isla"
                    } else {
                        pomodoroKey = register(shortcut) { [weak self] in
                            self?.pomodoro?.toggle()
                            self?.island?.showPomodoroStatus()
                        }
                        if pomodoroKey == nil { pomodoroError = Self.unavailable(shortcut) }
                    }
                }
            }
            settings.shortcutError = toggleError
            settings.pomodoroShortcutError = pomodoroError
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeShortcuts() }
        }
    }

    private func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor @Sendable () -> Void) -> GlobalHotKey? {
        let hotKey = GlobalHotKey(shortcut: shortcut) {
            Logger.app.info("Atajo: \(shortcut.label, privacy: .public)")
            action()
        }
        if hotKey == nil { Logger.app.error("No se pudo registrar el atajo \(shortcut.label, privacy: .public)") }
        return hotKey
    }

    private static func unavailable(_ shortcut: HotKeyShortcut) -> String {
        "No se pudo usar \(shortcut.label): quizá lo tiene otra app"
    }

    // yabaibar://refresh sigue funcionando para usarlo a mano; yabaibar://snapshot solo en DEBUG
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "yabaibar" {
            switch url.host() {
            case "refresh":
                Logger.app.info("Aviso: yabaibar://refresh")
                store?.requestRefresh()
            #if DEBUG
            case "snapshot":
                let peek: IslandPeek? = switch url.query() {
                case "aviso": .track
                case "aviso-pomodoro": .pomodoro(PomodoroPeek(phase: .shortBreak, kind: .started(minutes: 5)))
                default: nil
                }
                island?.saveSnapshot(expanded: url.query() == "abierta", hoveringCard: url.query() == "hover", peek: peek)
            case "stress":
                island?.stressTest()
            case "pomodoro-demo":
                pomodoro?.startDemo()
            #endif
            default:
                Logger.app.info("URL sin acción: \(url.absoluteString, privacy: .public)")
            }
        }
    }
}
