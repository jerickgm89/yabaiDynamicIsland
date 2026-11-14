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
    private var tools: DevTools?
    private var notices: NoticeCenter?
    private var calendar: CalendarStore?
    private var clipboard: ClipboardStore?
    private var tray: TrayStore?
    private var desktopControl: DesktopControlStore?
    private var maintenance: YabaiMaintenance?
    private var toggleKey: GlobalHotKey?
    private var pomodoroKey: GlobalHotKey?
    private var trackpad: TrackpadMonitor?
    private var signals: YabaiSignals?
    private var desktopShortcuts: DesktopShortcutAssistant?
    private var settingsWindow: SettingsWindow?
    private var welcome: WelcomeWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshToken: Int32 = NOTIFY_TOKEN_INVALID
    private var terminationSignal: DispatchSourceSignal?

    // Las señales de yabai y los atajos de skhd avisan con `notifyutil -p com.jerickdev.yabaibar.refresh`.
    // La notificación llega a la instancia que está corriendo; una URL pasaría por LaunchServices,
    // que con dos copias de la app (la de build/ y la de /Applications) abría la otra
    nonisolated static let refreshNotificationName = "com.jerickdev.yabaibar.refresh"

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
        let focuser = ShortcutFocuser()
        let launchAtLogin = LaunchAtLogin()
        // En los tests la app hace de host y xcodebuild la cierra sin avisar (sin SIGTERM): el adaptador de música
        // quedaría huérfano en cada pasada, así que ahí no se arranca
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // Los atajos «Ir al escritorio N» de los escritorios nuevos. En los tests no: escribiría los atajos de macOS
        let desktopShortcuts = isTestHost
            ? nil : DesktopShortcutAssistant(store: store, settings: settings, writer: SymbolicHotKeysWriter())
        self.desktopShortcuts = desktopShortcuts
        let welcome = WelcomeWindow(
            settings: settings, store: store, focuser: focuser, launchAtLogin: launchAtLogin,
            addDesktopShortcuts: { desktopShortcuts?.offer() }
        )
        self.welcome = welcome
        let claudeConnection = ClaudeConnection(
            file: ClaudeSettingsFile(url: ClaudeSettingsFile.defaultURL, helperPath: ClaudeConnection.helperPath)
        )
        // El calendario de la pestaña Utilidades. Solo lee los eventos y solo pide el permiso cuando el usuario pulsa «Dar acceso»
        let calendar = CalendarStore(source: EventKitSource(), settings: settings)
        self.calendar = calendar
        // El portapapeles: el historial está apagado hasta que el usuario lo enciende (macOS pregunta antes de dejar leerlo)
        let clipboard = ClipboardStore(
            source: SystemClipboard(), picker: SystemColorPicker(), settings: settings,
            persistence: ClipboardPersistence(url: ClipboardPersistence.defaultURL)
        )
        self.clipboard = clipboard
        // La bandeja de archivos: lo que se suelta en la isla, por referencia, guardado en UserDefaults
        let tray = TrayStore(defaults: .standard)
        self.tray = tray
        // El panel de yabai de Escritorios: las ventanas del escritorio activo y lo que se pulsa, con el mismo cliente que lo demás
        let desktopControl = DesktopControlStore(query: yabai, control: yabai, settings: settings)
        desktopControl.onChanged = { [weak store] in store?.requestRefresh() }
        self.desktopControl = desktopControl
        // Lo que la app hace por yabai fuera de la isla: contar cómo está, volver a poner lo recordado tras un reinicio y reiniciarlo
        let maintenance = YabaiMaintenance(client: yabai, settings: settings, store: store)
        self.maintenance = maintenance
        let settingsWindow = SettingsWindow(
            settings: settings, launchAtLogin: launchAtLogin, claude: claudeConnection, calendar: calendar, clipboard: clipboard,
            maintenance: maintenance
        ) {
            welcome.show()
        }
        self.settingsWindow = settingsWindow
        let menu = AppMenu(
            store: store, launchAtLogin: launchAtLogin, settingsWindow: settingsWindow,
            welcomeWindow: welcome, pomodoro: pomodoro, settings: settings, maintenance: maintenance
        )
        self.menu = menu
        // Las señales que refrescan la isla, sin tocar el yabairc. En los tests no: cambiarían el yabai real
        if !isTestHost {
            let signals = YabaiSignals(client: yabai, settings: settings, store: store)
            signals.onYabaiRestarted = { [weak maintenance] in maintenance?.yabaiRestarted() }
            self.signals = signals
            maintenance.start()
        }
        let media = NowPlayingStore(adapter: isTestHost ? nil : MediaRemoteAdapter(), settings: settings)
        self.media = media
        let claude = ClaudeSessions(connection: claudeConnection)
        let tools = DevTools(
            system: SystemMonitor(), ports: PortsMonitor(), docker: DockerMonitor(), claude: claude,
            git: GitMonitor(settings: settings), notices: NoticeLog(), settings: settings
        )
        self.tools = tools
        // Los avisos del ayudante `yb` (los hooks de Claude Code) y la vigilancia de los repositorios de Git. En los tests no:
        // serían las sesiones y los repositorios de verdad
        if !isTestHost {
            tools.git.start()
            calendar.start()
            clipboard.start()
            let notices = NoticeCenter()
            let terminal = TerminalNotices(settings: settings)
            notices.start { [weak self] message in
                claude.handle(message)
                // Un comando largo que terminó, o un `yb aviso`: la isla cerrada lo dice y el módulo Avisos lo guarda
                if let result = terminal.handle(message) { self?.island?.terminalNotice(result) }
            }
            self.notices = notices
        }
        let island = IslandController(
            store: store, icons: AppIcons(), menu: menu, focuser: focuser, settings: settings, media: media,
            keepAwake: KeepAwake(), pomodoro: pomodoro, calendar: calendar, clipboard: clipboard, tray: tray, desktopControl: desktopControl, tools: tools
        )
        self.island = island
        island.onMissingShortcut = { [weak desktopShortcuts] in desktopShortcuts?.offer() }
        island.onOpenSettings = { settingsWindow.show(tab: $0) }
        desktopShortcuts?.onAdded = { island.shortcutsAdded($0) }
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
                    self?.signals?.verify()
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

        // La primera vez, lo que hace falta para que todo funcione
        if !isTestHost, !settings.hasSeenWelcome {
            settings.hasSeenWelcome = true
            welcome.show()
        }
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
                // Opciones: abierta, hover, aviso, aviso-pomodoro, aviso-claude, aviso-claude-fin, aviso-git, aviso-git-ci, aviso-terminal,
                // aviso-terminal-error, claude-demo, git-demo, avisos-demo, calendario-demo, portapapeles-demo, portapapeles-herramientas, novedades o
                // bienvenida; pestaña=utilidades (o
                // tab=utilities) la abre en esa pestaña; y notch=185x32&pantalla=1512x982 para simular otro Mac
                // (por ejemplo, "abierta&notch=185x32&pantalla=1512x982")
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let flags = Set(items.map(\.name))
                if flags.contains("bienvenida") {
                    welcome?.saveSnapshot()
                    continue
                }
                if let name = items.first(where: { $0.name == "ajustes" })?.value,
                   let tab = SettingsWindow.Tab.allCases.first(where: { $0.title.lowercased().hasPrefix(name.lowercased()) }) {
                    settingsWindow?.saveSnapshot(tab: tab)
                    continue
                }
                let peek: IslandPeek? = flags.contains("aviso") ? .track
                    : flags.contains("aviso-pomodoro") ? .pomodoro(PomodoroPeek(phase: .shortBreak, kind: .started(minutes: 5)))
                    : flags.contains("aviso-claude")
                    ? .claude(ClaudePeek(kind: .asks, folder: "tienda", detail: "Claude needs your permission to use Bash"))
                    : flags.contains("aviso-claude-fin") ? .claude(ClaudePeek(kind: .finished, folder: "tienda", detail: "tras 2 min"))
                    : flags.contains("aviso-git")
                    ? .notice(GitNotice(repo: "tienda", kind: .unpushed(commits: 3)).notice)
                    : flags.contains("aviso-git-ci")
                    ? .notice(GitNotice(repo: "tienda", kind: .ci(.failed)).notice)
                    : flags.contains("aviso-terminal")
                    ? .notice(TerminalNoticeText.islandNotice(TerminalNotice(source: .command(name: "npm", exitCode: 0, seconds: 145), terminal: "ghostty")))
                    : flags.contains("aviso-terminal-error")
                    ? .notice(TerminalNoticeText.islandNotice(TerminalNotice(source: .command(name: "cargo", exitCode: 101, seconds: 42), terminal: "ghostty")))
                    : nil
                let value = { (name: String) in items.first { $0.name == name }?.value.flatMap(Self.size) }
                let simulated = value("notch").flatMap { notch in value("pantalla").map { (screen: $0, notch: notch) } }
                let tab = items.first { $0.name == "pestaña" || $0.name == "tab" }?.value.flatMap(Self.tab)
                let badges = flags.contains("novedades")
                // fila=puertos o fila=docker: la primera fila de ese módulo con el puntero encima
                let hoveredModule = items.first { $0.name == "fila" }?.value.flatMap { name in
                    ModuleID.allCases.first { $0.title.lowercased().hasPrefix(name.lowercased()) }
                }
                // El monitor del sistema solo mide con la pestaña a la vista: antes del snapshot se hace una medida
                Task { @MainActor in
                    if tab == .developer { await self.tools?.sampleOnce() }
                    // claude-demo: tres sesiones inventadas, una con pregunta, en vez de las de verdad
                    if flags.contains("claude-demo") { self.tools?.claude.injectDemo() }
                    // git-demo: tres repositorios inventados, uno con el CI roto
                    if flags.contains("git-demo") { self.tools?.git.injectDemo() }
                    // portapapeles-demo y portapapeles-herramientas: un historial y unas muestras inventados, sin leer el portapapeles
                    let clipboardDemo = flags.contains("portapapeles-demo") || flags.contains("portapapeles-herramientas")
                    if clipboardDemo { self.clipboard?.injectDemo(mode: flags.contains("portapapeles-herramientas") ? .tools : .history) }
                    // bandeja-demo: archivos inventados en la bandeja; con bandeja-arrastre, además el módulo resaltado como al
                    // arrastrar un archivo sobre la isla
                    let trayDemo = flags.contains("bandeja-demo") || flags.contains("bandeja-arrastre")
                    if trayDemo { self.tray?.injectDemo(count: flags.contains("bandeja-vacia") ? 0 : 7) }
                    // yabai-demo, yabai-pila, yabai-sa y yabai-mensaje: ventanas inventadas en el panel de yabai de Escritorios
                    let yabaiDemo = flags.contains("yabai-demo") || flags.contains("yabai-pila")
                    if yabaiDemo {
                        self.desktopControl?.injectDemo(
                            layout: flags.contains("yabai-pila") ? .stack : .bsp, scriptingAddition: flags.contains("yabai-sa"),
                            message: flags.contains("yabai-mensaje") ? DesktopControlMessage(text: DesktopControlText.needsScriptingAddition, isError: true) : nil
                        )
                    }
                    // calendario-demo: eventos inventados (con permiso, aunque no lo haya) en el módulo Calendario
                    let calendarDemo = flags.contains("calendario-demo")
                    if calendarDemo { self.calendar?.injectDemo() }
                    // avisos-demo: cuatro avisos inventados en el módulo Avisos
                    let noticesDemo = flags.contains("avisos-demo")
                    if noticesDemo { self.tools?.notices.injectDemo() }
                    defer {
                        if noticesDemo { self.tools?.notices.resetInjected() }
                        if calendarDemo { self.calendar?.resetInjected() }
                        if clipboardDemo { self.clipboard?.resetInjected() }
                        if trayDemo { self.tray?.resetInjected() }
                        if yabaiDemo { self.desktopControl?.resetInjected() }
                        if flags.contains("claude-demo") { self.tools?.claude.resetInjected() }
                        if flags.contains("git-demo") { self.tools?.git.resetInjected() }
                    }
                    self.island?.saveSnapshot(
                        expanded: flags.contains("abierta"), hoveringCard: flags.contains("hover"), peek: peek,
                        simulating: simulated, tab: tab, badges: badges, hoveringRowOf: hoveredModule,
                        trayTargeted: flags.contains("bandeja-arrastre")
                    )
                }
            case "abrir":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                island?.debugOpen(tab: items.first { $0.name == "pestaña" || $0.name == "tab" }?.value.flatMap(Self.tab) ?? .desktops)
            case "cerrar":
                island?.debugClose()
            case "bandeja-prueba":
                island?.debugTrayDrag()
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

    #if DEBUG
    /// "185x32" → 185 × 32
    private static func size(_ text: String) -> CGSize? {
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// "utilidades" o "utilities" → la pestaña de Utilidades
    private static func tab(_ name: String) -> IslandTab? {
        let name = name.lowercased()
        return IslandTab.allCases.first { $0.title.lowercased().hasPrefix(name) || String(describing: $0).hasPrefix(name) }
    }
    #endif
}
