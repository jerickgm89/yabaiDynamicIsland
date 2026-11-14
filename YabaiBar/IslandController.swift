import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import os

// Coloca la isla sobre el notch, la anima cuando cambian los espacios, la abre con el puntero o a petición (⌥I y
// el gesto de 3 o 4 dedos) y, abierta, lleva al escritorio de la tarjeta que se pulse; cualquier otro clic abre el menú.
// En reposo la ventana mide justo lo que la isla, para no tapar los clics de la barra de menús alrededor.
@MainActor
final class IslandController {
    // Valores de Atoll para el contenido, el hover, la apertura y el cierre
    static let changeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let hoverAnimation = Animation.bouncy.speed(1.2)
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 1.0)
    static let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let reducedAnimation = Animation.easeInOut(duration: 0.2)
    // Cambio de escritorio: las alas se recogen y vuelven a salir con un rebote suave, sin prisa. Son los valores
    // de la velocidad normal; la de los ajustes los acelera o los frena (SwitchSpeed)
    static let tuckAnimation = Animation.smooth(duration: 0.3)
    static let untuckAnimation = Animation.spring(response: 0.6, dampingFraction: 0.8)
    /// Tiempo mínimo recogidas, para que se vea el gesto aunque yabai responda enseguida
    static let minimumTuck: Duration = .milliseconds(300)
    /// Si no llega contenido nuevo (gesto cancelado o mismo escritorio), las alas vuelven solas
    static let tuckTimeout: Duration = .milliseconds(900)
    /// Oculta más que esto no es un cambio de escritorio sino Mission Control: al volver, las alas salen enseguida
    static let longAbsence: Duration = .milliseconds(1500)
    static let reappearDelay: Duration = .milliseconds(250)
    /// Fundido de la ventana entera al empezar un cambio de escritorio
    static let windowFadeDuration: TimeInterval = 0.15
    /// Lo que se espera, tras un cambio, para devolver la ventana a su tamaño justo
    static let settleDelay: Duration = .milliseconds(1400)
    /// Lo que tiene que estar el puntero encima para que la isla se abra
    static let openDelay: Duration = .milliseconds(300)
    static let pointerCheckInterval: Duration = .milliseconds(120)
    /// Las tarjetas se iluminan bajo el puntero y se hunden al pulsarlas
    static let cardAnimation = Animation.smooth(duration: 0.2)
    /// Al cambiar de pestaña la isla crece o se encoge y el contenido se funde
    static let tabAnimation = Animation.spring(response: 0.4, dampingFraction: 0.95)
    /// Las teclas de cambiar de pestaña con la isla abierta con el atajo o el gesto, como en vim: h a la izquierda y
    /// l a la derecha
    static let vimTabKeys: [(keyCode: Int, step: IslandTab.Step)] = [(kVK_ANSI_H, .previous), (kVK_ANSI_L, .next)]
    /// Tras cambiar de pestaña con el teclado, la isla puede encogerse y dejar el puntero fuera: no se cierra por eso
    /// hasta pasado este tiempo
    static let tabResizeGrace: Duration = .seconds(2)
    /// Al elegir un escritorio la isla se recoge entera en el notch; el atajo se pulsa cuando ya casi lo ha hecho,
    /// para que el encogimiento se vea antes de que macOS empiece a deslizar
    static let switchDelay: Duration = .milliseconds(200)
    /// Margen de la ventana alrededor de la isla para que quepa la sombra
    static let shadowMargin: CGFloat = 16
    /// TIDAL manda dos avisos seguidos por cada canción nueva: el aviso espera a que se calme
    static let trackPeekDelay: Duration = .milliseconds(600)
    /// Lo que se hunde el botón al cambiar de canción con el gesto de lado
    static let swipeFlash: Duration = .milliseconds(180)

    private enum Expansion { case closed, peek, open }

    /// Alto del lienzo de la isla: cabe la pestaña más alta (Desarrollador, de 294 pt con el notch del 16") con su sombra
    static let canvasHeight: CGFloat = 320

    private let panel = IslandPanel(contentRect: .zero)
    private let container = IslandContainerView()
    private let hosting: IslandHostingView
    private let model = IslandModel()
    private let store: SpacesStore
    private let icons: AppIcons
    private let focuser: ShortcutFocuser
    private let settings: AppSettings
    private let media: NowPlayingStore
    private let keepAwake: KeepAwake
    private let pomodoro: PomodoroStore
    private let tools: DevTools
    private let calendar: CalendarStore
    private let clipboard: ClipboardStore
    private let tray: TrayStore
    private var geometry: NotchGeometry?
    private var screenWidth: CGFloat = 0
    // Copias de lo dibujado. No se leen del modelo dentro de render(): withObservationTracking
    // registraría el modelo y cada cambio volvería a llamar a render() sin fin
    private var currentLayout = IslandLayout(spaces: [])
    private var currentSpaces: [SpaceSummary] = []
    private var currentFailed = false
    /// Hay música: la isla abierta tiene la franja "Ahora suena" y la cerrada, las barras
    private var currentHasMedia = false
    /// Hay sesión de Pomodoro: la isla cerrada tiene su anillo
    private var currentHasPomodoro = false
    /// Sin sesión, la parte del Pomodoro de Utilidades solo tiene el botón de empezar
    private var currentPomodoroIdle = true
    /// La pestaña que se ve con la isla abierta y la última que se eligió: con el atajo o el gesto se abre en ella.
    /// Son copias, como las de arriba: el modelo no se lee dentro de render()
    private var currentTab = IslandTab.desktops
    private var lastTab = IslandTab.desktops
    private var tabChangedAt: ContinuousClock.Instant?
    private var tabBadges: [IslandTab: TabBadge] = [:]
    /// La novedad de Git que todavía no has visto en Desarrollador: rojo si falló el CI de un push, azul si un aviso no llegó a verse
    private var developerNews: TabBadge?
    /// El aviso que enseña la isla cerrada en lugar de los espacios (canción nueva o batería)
    private var currentPeek: IslandPeek?
    private var trackChanges = TrackChangeDetector()
    private var batteryEvents = BatteryEventDetector()
    private var peekTask: Task<Void, Never>?
    private var sideSwipe = SideSwipeTracker()
    private var expansion = Expansion.closed
    private var settleTask: Task<Void, Never>?
    private var tuckedAt: ContinuousClock.Instant?
    private var untuckTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var pointerWatch: Task<Void, Never>?
    /// Abierta con toggle() y el puntero todavía sin pasar por la isla: no se cierra por no tenerlo encima
    private var waitingForPointer = false
    /// Mientras está abierta con toggle(), Esc y los clics en otras apps la cierran
    private var escapeKey: GlobalHotKey?
    /// Mientras está abierta: ⌥← y ⌥→ cambian de pestaña. Abierta con toggle(), además h y l
    private var tabKeys: [GlobalHotKey] = []
    private var vimKeys: [GlobalHotKey] = []
    private var clickMonitor: Any?
    private var autoHideTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    /// Al pulsar la tarjeta de un escritorio sin atajo: ofrecer añadirlo (DesktopShortcutAssistant)
    var onMissingShortcut: (() -> Void)?
    /// El engranaje de la isla abierta (y «Conectar» de Claude Code): abrir los ajustes, en esa pestaña si se dice
    var onOpenSettings: ((SettingsWindow.Tab?) -> Void)?
    private var occlusionObserver: NSObjectProtocol?

    init(
        store: SpacesStore, icons: AppIcons, menu: AppMenu, focuser: ShortcutFocuser, settings: AppSettings,
        media: NowPlayingStore, keepAwake: KeepAwake, pomodoro: PomodoroStore, calendar: CalendarStore,
        clipboard: ClipboardStore, tray: TrayStore, tools: DevTools
    ) {
        self.store = store
        self.calendar = calendar
        self.clipboard = clipboard
        self.tray = tray
        self.icons = icons
        self.focuser = focuser
        self.settings = settings
        self.media = media
        self.keepAwake = keepAwake
        self.pomodoro = pomodoro
        self.tools = tools
        hosting = IslandHostingView(rootView: IslandView(model: model))
        // Que la vista no cambie el tamaño de la ventana: el marco lo decide NotchGeometry
        hosting.sizingOptions = []
        hosting.menuOnClick = menu.menu
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        hosting.onPointerMoved = { [weak self] in self?.updateHoveredCard() }
        hosting.onPress = { [weak self] in self?.pressCard() ?? false }
        hosting.onRelease = { [weak self] in self?.releaseCard() }
        hosting.onScroll = { [weak self] sample in self?.scrolled(sample) }
        // Arrastrar un archivo desde la bandeja hacia otra app, y soltar uno sobre la isla. El destino va en el contenedor: AppKit sube
        // por las vistas hasta la primera registrada para el tipo, y NSHostingView no deja sobrescribir sus métodos de destino
        hosting.onDragOut = { [weak self] in self?.dragOutURLs() ?? [] }
        hosting.onDragEnded = { [weak self] in self?.updateHoveredCard() }
        let dropHandlers = FileDropHandlers(
            over: { [weak self] in self?.fileDragOver() ?? false },
            left: { [weak self] in self?.fileDragLeft() },
            dropped: { [weak self] urls in self?.fileDropped(urls) ?? false }
        )
        container.dropHandlers = dropHandlers
        // El hosting va dentro de un contenedor y no como contentView: si lo es, intenta ajustar (y animar)
        // el tamaño de la ventana a la isla, choca con nuestros setFrame y, con cambios de espacio muy
        // seguidos, AppKit lanza una excepción por demasiadas pasadas de restricciones y cierra la app
        container.addSubview(hosting)
        panel.contentView = container

        updateGeometry()
        observeStore()
        observeMedia()
        observePomodoro()
        observeSystem()
        observeModules()
        observeClaude()
        observeCalendar()
        // El punto ya puede estar encendido (una reunión en menos de 15 min al arrancar): sin esto, nada lo cambiaría después
        updateCalendarBadge()
        calendar.onNotice = { [weak self] event, moment in self?.calendarNotice(event, at: moment) }
        observeClipboard()
        observeTray()
        clipboard.onColorCopied = { [weak self] hex in self?.colorCopied(hex) }
        tools.claude.onOutcome = { [weak self] outcome in self?.claudeOutcome(outcome) }
        tools.git.onNotice = { [weak self] notice in self?.gitNotice(notice) }
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateGeometry()
                self?.render()
            }
        }

        // La ventana deja de verse en cuanto empieza un cambio de escritorio (al iniciar el gesto del trackpad
        // o al pulsar ⌥N), entre 0,1 y casi 1 s antes de activeSpaceDidChange: ahí se recogen las alas
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
    }

    // withObservationTracking avisa una sola vez y antes del cambio: se vuelve a registrar en el siguiente ciclo
    private func observeStore() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    // El notch se mide en la pantalla, así que vale para cualquier Mac con notch y cualquier escala de pantalla
    private func updateGeometry() {
        guard let screen = Self.notchScreen() else { return }
        let newGeometry = screen.notchGeometry
        if newGeometry != geometry || screen.frame.width != screenWidth {
            let notch = newGeometry.notch.size
            let kind = newGeometry.hasNotch ? "notch" : "sin notch, uno de reserva de"
            let measure = "\(Self.points(notch.width)) × \(Self.points(notch.height)) pt"
            let size = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
            let description = "Pantalla \(screen.displayUUID ?? "?"): \(kind) \(measure) en \(size) (\(MacModels.current))"
            Logger.app.info("\(description, privacy: .public)")
        }
        screenWidth = screen.frame.width
        container.canvasSize = CGSize(width: screen.frame.width, height: Self.canvasHeight)
        geometry = newGeometry
    }

    // Las medidas del notch pueden no ser enteras con algunas escalas de pantalla
    private static func points(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    private func render() {
        let failed = store.lastError != nil
        apply(spaces: failed ? [] : store.spaces, failed: failed)
    }

    private func apply(spaces: [SpaceSummary], failed: Bool) {
        guard let geometry else { return }
        // Con el botón de mantener despierto apagado en Ajustes, el Mac deja de mantenerse despierto
        if !settings.keepAwakeButton { keepAwake.stop() }
        let layout = IslandLayout(spaces: spaces, statusItems: statusItems())
        currentLayout = layout
        currentSpaces = spaces
        currentFailed = failed
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let description = Self.title(for: spaces, failed: failed)
        let update = {
            self.model.centerWidth = geometry.centerWidth
            self.model.height = geometry.notch.height
            self.model.layout = layout
            self.model.expanded = self.expandedLayout(for: spaces, geometry: geometry)
            self.model.icons = self.icons.icons(for: spaces)
            self.model.fallbackText = spaces.isEmpty ? description : nil
            self.model.reduceMotion = reduceMotion
            self.model.keepAwakeActive = self.keepAwake.isActive
            self.model.tabBadges = self.tabBadges
        }

        // La ventana crece antes de animar y se ajusta al terminar, para que la isla nunca se recorte
        growWindow()
        if let tuckedAt {
            // Alas recogidas por un cambio de escritorio: el contenido cambia sin animar, porque no se ve,
            // y después vuelven a salir con el contenido nuevo
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
            let minimumTuck = settings.switchSpeed.scaled(Self.minimumTuck)
            scheduleUntuck(after: max(.zero, minimumTuck - (ContinuousClock.now - tuckedAt)))
        } else {
            withAnimation(reduceMotion ? Self.reducedAnimation : Self.changeAnimation, update)
        }
        settleWindow()
        Logger.app.info("Isla: \(description, privacy: .public) (alas de \(Int(layout.wingWidth)) pt)")
    }

    // Lo que va al final del ala derecha. Se lee aquí, dentro de render(), para que los cambios de la música y de
    // mantener despierto (y sus ajustes) vuelvan a dibujar las alas
    private func statusItems() -> [IslandLayout.StatusItem] {
        var items: [IslandLayout.StatusItem] = []
        if currentHasMedia && settings.showMusicBars { items.append(.music) }
        if keepAwake.isActive { items.append(.keepAwake) }
        if tabBadges[.utilities] != nil { items.append(.utilities) }
        if tabBadges[.developer] != nil { items.append(.developer) }
        if currentHasPomodoro && settings.showPomodoroRing { items.append(.pomodoro) }
        return items
    }

    // MARK: - Cambio de escritorio

    /// Aviso de macOS de que el cambio de escritorio terminó. Normalmente las alas ya se recogieron al
    /// empezar (ver occlusionChanged); si no, se recogen ahora. Vuelven a salir cuando llega el contenido nuevo.
    func spaceDidChange() {
        tuckWings()
        if tuckedAt != nil { scheduleUntuck(after: Self.tuckTimeout) }
    }

    private func occlusionChanged() {
        let visible = panel.occlusionState.contains(.visible)
        Logger.app.info("Isla: \(visible ? "visible" : "oculta", privacy: .public) (oclusión)")
        if visible {
            // Vuelve a verse al cerrar Mission Control: si ahí se creó o se quitó un escritorio, yabai no avisa
            // (ni space_created ni space_destroyed), así que se consulta ahora. Al cambiar de escritorio coincide
            // con activeSpaceDidChange y el debounce del store los junta en uno
            store.requestRefresh()
            // De vuelta en pantalla: si no llega contenido nuevo (gesto cancelado o Mission Control sin cambios), las
            // alas vuelven solas. Tras una ausencia larga (Mission Control) no hay escritorio que deslizar: salen en
            // cuanto da tiempo a que llegue el refresco
            if let tuckedAt {
                let wasLong = ContinuousClock.now - tuckedAt > Self.longAbsence
                scheduleUntuck(after: wasLong ? Self.reappearDelay : Self.tuckTimeout)
            }
        } else {
            tuckWings()
            // Oculta, SwiftUI deja de dibujarla: al volver, macOS enseñaría un instante el último fotograma
            // (la isla entera) y luego saltaría a recogida, y durante el gesto se verían fotogramas a medias.
            // La ventana se apaga con un fundido del propio sistema de ventanas y se enciende ya recogida.
            if tuckedAt != nil { fadeWindow(to: 0) }
        }
    }

    private func fadeWindow(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.windowFadeDuration
            panel.animator().alphaValue = alpha
        }
    }

    private func tuckWings() {
        guard expansion == .closed, !currentSpaces.isEmpty, tuckedAt == nil else { return }
        tuckedAt = .now
        untuckTask?.cancel()
        // El aviso se recoge con las alas
        peekTask?.cancel()
        currentPeek = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = reduceMotion ? Self.reducedAnimation : settings.switchSpeed.animation(Self.tuckAnimation)
        withAnimation(animation) {
            model.wingsTucked = true
            model.peek = nil
        }
    }

    private func scheduleUntuck(after delay: Duration) {
        untuckTask?.cancel()
        untuckTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            untuckWings()
        }
    }

    private func untuckWings() {
        tuckedAt = nil
        // Recogida, la isla mide lo que el notch y es negra como él: encenderla de golpe no se nota
        panel.alphaValue = 1
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = reduceMotion ? Self.reducedAnimation : settings.switchSpeed.animation(Self.untuckAnimation)
        withAnimation(animation) { model.wingsTucked = false }
        settleWindow()
    }

    private func expandedLayout(
        for spaces: [SpaceSummary], geometry: NotchGeometry, screenWidth: CGFloat? = nil, tab: IslandTab? = nil
    ) -> IslandExpandedLayout {
        IslandExpandedLayout(
            spaces: spaces,
            minBodyWidth: geometry.centerWidth + 2 * currentLayout.wingWidth,
            maxBodyWidth: IslandExpandedLayout.maxBodyWidth(
                screenWidth: screenWidth ?? self.screenWidth, topRadius: IslandView.openTopRadius
            ),
            topHeight: geometry.notch.height,
            tab: tab ?? currentTab,
            tabs: IslandTab.allCases,
            developerModules: ModuleID.modules(of: .developer).filter { (settings.showDocker || $0 != .docker) && (settings.showGit || $0 != .git) },
            hasMedia: currentHasMedia,
            hasKeepAwake: settings.keepAwakeButton,
            hasPomodoro: settings.showPomodoro,
            pomodoroIdle: currentPomodoroIdle,
            hasSettingsButton: true
        )
    }

    // MARK: - Pomodoro

    // Aparte de render(), como la música: el Pomodoro cambia de estado y no tiene que recalcular las alas
    private func observePomodoro() {
        withObservationTracking {
            updatePomodoro()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePomodoro() }
        }
    }

    private func updatePomodoro() {
        // Con el Pomodoro apagado en Ajustes, la sesión termina
        if !settings.showPomodoro, pomodoro.timer.isActive { pomodoro.stop() }
        let timer = pomodoro.timer
        let active = timer.isActive && settings.showPomodoro
        let appeared = active != currentHasPomodoro
        // Sin sesión, su parte de Utilidades solo tiene el botón de empezar
        let idleChanged = !timer.isActive != currentPomodoroIdle
        currentHasPomodoro = active
        currentPomodoroIdle = !timer.isActive
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) {
            // Con el Pomodoro activado, su parte de Utilidades se dibuja con sesión o sin ella
            model.pomodoro = settings.showPomodoro ? timer : nil
            model.pomodoroRounds = pomodoro.rules.durations.roundsUntilLongBreak
            model.pomodoroGoal = settings.pomodoroDailyGoal
            model.pomodoroFocusDuration = pomodoro.rules.durations.focus
        }
        // Si el anillo de la isla cerrada aparece o desaparece cambian las alas, y con la sesión, los botones
        if appeared || idleChanged { apply(spaces: currentSpaces, failed: currentFailed) }
    }

    // MARK: - Sistema

    // Aparte de render(), como la música: el monitor publica una medida cada 2 s y no tiene que recalcular las alas
    private func observeSystem() {
        withObservationTracking {
            updateSystem()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSystem() }
        }
    }

    // Sin animar: animar las barras entre medida y medida redibuja la isla (con su sombra) en cada fotograma durante
    // medio segundo, y era lo que más consumía con la pestaña abierta
    private func updateSystem() {
        model.system = tools.system.snapshot
    }

    // Las filas de Puertos y Docker, por el mismo camino y por lo mismo: cambian cada 3 s y no tienen que recalcular las alas
    private func observeModules() {
        withObservationTracking {
            updateModules()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModules() }
        }
    }

    private func updateModules() {
        model.moduleContent = tools.rowsContent()
    }

    // El punto naranja de Desarrollador mientras alguna sesión de Claude Code espera tu respuesta. El valor se lee dentro del
    // seguimiento y el cambio se aplica fuera, para que `apply()` no registre sus lecturas aquí
    private func observeClaude() {
        withObservationTracking {
            _ = tools.claude.waitingCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateDeveloperBadge()
                self?.observeClaude()
            }
        }
    }

    // El punto de Desarrollador, de un solo sitio porque lo piden dos cosas: naranja mientras una sesión de Claude Code espera tu
    // respuesta, que manda, y la novedad de Git (`developerNews`), hasta que abres la pestaña
    private func updateDeveloperBadge() {
        setBadge(.developer(claudeWaiting: tools.claude.waitingCount, news: developerNews), for: .developer)
    }

    // Lo que enseña el módulo Portapapeles: se lee dentro del seguimiento, como el calendario
    private func observeClipboard() {
        withObservationTracking {
            let snapshot = clipboard.snapshot
            if snapshot != model.clipboard { model.clipboard = snapshot }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeClipboard() }
        }
    }

    // Lo que enseña el módulo Bandeja: sus archivos y cuáles faltan
    private func observeTray() {
        withObservationTracking {
            let snapshot = tray.snapshot
            if snapshot != model.tray { model.tray = snapshot }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTray() }
        }
    }

    // Lo que enseña el módulo Calendario y el punto azul de Utilidades (un evento empieza en menos de 15 min). El módulo se lee dentro
    // del seguimiento, como las filas de Puertos y Docker; el punto, como el de Claude, se lee dentro y se aplica fuera para que
    // `apply()` no registre sus lecturas aquí
    private func observeCalendar() {
        withObservationTracking {
            let snapshot = calendar.snapshot
            if snapshot != model.calendar { model.calendar = snapshot }
            _ = calendar.isBadgeOn
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateCalendarBadge()
                self?.observeCalendar()
            }
        }
    }

    private func updateCalendarBadge() {
        setBadge(calendar.isBadgeOn ? .info : nil, for: .utilities)
    }

    /// Un evento está a 5 minutos de empezar: se guarda en el módulo Avisos y la isla cerrada lo dice unos segundos (el punto azul de
    /// Utilidades ya lleva encendido desde los 15 min, así que no deja otro rastro)
    private func calendarNotice(_ event: CalendarEvent, at moment: Date) {
        let title = ClaudeHookText.clean(event.title, limit: 60)
        let subtitle = CalendarTimeline.noticeSubtitle(for: event, at: moment, calendar: calendar.calendar)
        tools.notices.record(NoticeEntry(date: moment, tone: .active, title: title, detail: subtitle, origin: .calendar))
        announce(
            IslandNotice(symbol: "calendar.badge.clock", tone: .info, title: title, subtitle: subtitle, priority: 30), failed: false,
            leavesTrace: false
        )
    }

    /// Un aviso de Git: se guarda en el módulo Avisos y la isla cerrada lo dice unos segundos
    private func gitNotice(_ notice: GitNotice) {
        tools.notices.record(notice.entry(date: Date()))
        announce(notice.notice, failed: notice.kind == .ci(.failed))
    }

    /// Un aviso de la terminal ya aceptado por `TerminalNotices` (los manda `yb`): siempre queda en el módulo Avisos y, salvo que la
    /// terminal esté delante, la isla cerrada lo dice unos segundos
    func terminalNotice(_ result: TerminalNotices.Result) {
        tools.notices.record(result.entry)
        guard !result.suppressPeek else { return }
        announce(result.notice, failed: result.failed)
    }

    /// Un aviso genérico (Git, terminal): la isla cerrada lo dice unos segundos. Cada aviso sale una sola vez, así que uno que no
    /// puede verse ahora (isla abierta, pantalla completa, un cambio de escritorio o un aviso más importante en pantalla) no se
    /// pierde sin rastro: deja un punto azul en Desarrollador. Lo que salió mal (un CI o un comando que falló) deja el rojo, se vea
    /// o no. Si estás mirando Desarrollador no hace falta
    private func announce(_ notice: IslandNotice, failed: Bool, leavesTrace: Bool = true) {
        let peek = IslandPeek.notice(notice)
        let shown = canShow(peek)
        if shown { schedulePeek(peek) }
        let news: TabBadge? = failed ? .alert : shown ? nil : .info
        guard leavesTrace || failed, let news, !(expansion == .open && currentTab == .developer) else { return }
        // El rojo no lo tapa el azul
        if developerNews != .alert { developerNews = news }
        updateDeveloperBadge()
    }

    /// Una sesión de Claude Code pregunta o terminó (ClaudeSessions): se guarda en el módulo Avisos y la isla cerrada lo dice unos
    /// segundos. Al terminar, Git mira si dejó cambios sin commit
    private func claudeOutcome(_ outcome: ClaudeOutcome) {
        let sessionID: String
        switch outcome {
        case .asks(let id, _, _), .finished(let id, _, _): sessionID = id
        }
        if case .finished = outcome { tools.git.claudeFinished(sessionID: sessionID) }
        guard let peek = ClaudePeek.make(for: outcome, notifyFinished: settings.claudeNotifyFinished) else { return }
        tools.notices.record(peek.entry(sessionID: sessionID, date: Date()))
        schedulePeek(.claude(peek))
    }

    /// Dice a DevTools qué pestaña se ve: la elegida con la isla abierta, ninguna con la isla cerrada. Se llama al abrir,
    /// al cerrar (también al recogerse en el notch) y al cambiar de pestaña, y en ningún otro sitio
    private func reportVisibleTab() {
        let visible = expansion == .open ? currentTab : nil
        tools.setVisibleTab(visible)
        calendar.setVisible(visible == .utilities)
        // La bandeja mira el disco al ver la pestaña (no hay temporizador): lo movido o borrado se nota al abrirla
        if visible == .utilities { tray.refresh() }
        // El punto de Git avisa hasta que abres la pestaña
        if visible == .developer, developerNews != nil {
            developerNews = nil
            updateDeveloperBadge()
        }
    }

    // MARK: - Ahora suena

    // Aparte de render(): lo que suena cambia a menudo y no tiene que volver a calcular las alas
    private func observeMedia() {
        withObservationTracking {
            updateMedia()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMedia() }
        }
    }

    private func updateMedia() {
        let nowPlaying = media.nowPlaying
        let artwork = media.artwork
        let sourceIcon = media.sourceIcon
        // Las barras se leen aquí para que este seguimiento también avise si cambia el ajuste
        let showsBars = nowPlaying != nil && settings.showMusicBars
        let barsChanged = showsBars != currentLayout.showsMusicIndicator && !currentLayout.isCollapsed
        let appeared = (nowPlaying != nil) != currentHasMedia
        currentHasMedia = nowPlaying != nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.changeAnimation) {
            model.nowPlaying = nowPlaying
            model.artwork = artwork
            model.sourceIcon = sourceIcon
        }
        // Si la música aparece o desaparece, cambian las alas (barras) y el alto de la isla abierta (franja)
        if appeared || barsChanged { apply(spaces: currentSpaces, failed: currentFailed) }
        if trackChanges.update(nowPlaying), settings.announceTracks { schedulePeek(.track, after: Self.trackPeekDelay) }
    }

    // MARK: - Avisos de la isla cerrada

    /// Aviso de BatteryMonitor: si el cargador cambia o la batería baja de un umbral, la isla lo enseña
    func batteryChanged(_ state: BatteryState) {
        guard let event = batteryEvents.update(state), settings.batteryAlerts else { return }
        Logger.app.info("Batería: \(String(describing: event), privacy: .public) al \(state.level) %")
        schedulePeek(.battery(event, level: state.level))
    }

    /// Tras el atajo del Pomodoro: cómo quedó (empezado, reanudado o en pausa), porque con la isla cerrada no se ve
    /// de otra forma más que en el color del anillo
    func showPomodoroStatus() {
        guard let peek = PomodoroPeek.status(of: pomodoro.timer, at: .now) else { return }
        schedulePeek(.pomodoro(peek))
    }

    /// Atajos de escritorio añadidos (DesktopShortcutAssistant): la isla cerrada lo dice unos segundos
    func shortcutsAdded(_ proposals: [DesktopShortcuts.Proposal]) {
        let announcement = DesktopShortcuts.announcement(for: proposals)
        schedulePeek(.shortcuts(title: announcement.title, subtitle: announcement.subtitle))
    }

    /// Aviso de PomodoroStore: el cambio de fase o lo que queda, en la isla cerrada
    func pomodoroEvent(_ event: PomodoroEvent) {
        guard settings.showPomodoro else { return }
        schedulePeek(.pomodoro(PomodoroPeek.make(for: event, timer: pomodoro.timer, rules: pomodoro.rules)))
    }

    // La canción nueva, la batería o el Pomodoro: la isla cerrada lo enseña unos segundos en lugar de los espacios.
    // Un aviso nuevo sustituye al que se esté viendo, salvo que sea menos importante
    private func schedulePeek(_ peek: IslandPeek, after delay: Duration = .zero) {
        if let currentPeek, currentPeek.priority > peek.priority { return }
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            setPeek(peek)
            try? await Task.sleep(for: peek.duration)
            guard !Task.isCancelled else { return }
            setPeek(nil)
        }
    }

    private func cancelPeek() {
        peekTask?.cancel()
        setPeek(nil)
    }

    // Solo con la isla cerrada, a la vista y con espacios: nunca mientras cambia el escritorio ni a pantalla completa
    private var canShowPeeks: Bool {
        expansion == .closed && tuckedAt == nil && !currentLayout.isCollapsed && !currentSpaces.isEmpty
    }

    /// Un aviso se vería ahora: la isla lo admite y no hay otro más importante en pantalla (`schedulePeek` lo descartaría)
    private func canShow(_ peek: IslandPeek) -> Bool {
        canShowPeeks && (currentPeek?.priority ?? 0) <= peek.priority
    }

    private func setPeek(_ peek: IslandPeek?) {
        guard peek != currentPeek else { return }
        guard peek == nil || canShowPeeks else { return }
        currentPeek = peek
        growWindow()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.changeAnimation) { model.peek = peek }
        settleWindow()
        if let peek { Logger.app.info("Isla: aviso \(peek.summary, privacy: .public)") }
    }

    // MARK: - Gesto de lado sobre la música

    // Dos dedos de lado sobre la franja de la isla abierta: a la izquierda, siguiente; a la derecha, anterior.
    // El gesto se sigue siempre, para que su estado no se desordene, y la posición se mira al dispararse
    private func scrolled(_ sample: SideSwipeTracker.Sample) {
        guard let direction = sideSwipe.track(sample), let (point, islandWidth, topHeight) = pointerInOpenIsland() else { return }
        // Sobre la tira de días del calendario, pasa de semana: dedos a la izquierda, la siguiente
        if model.expanded.calendarStripContains(point, islandWidth: islandWidth, topHeight: topHeight) {
            Logger.app.info("Gesto: \(direction == .left ? "semana siguiente" : "semana anterior", privacy: .public) en el calendario")
            calendar.shiftWeek(direction == .left ? 1 : -1)
            return
        }
        guard model.expanded.musicContains(point, islandWidth: islandWidth, topHeight: topHeight) else { return }
        let control: IslandExpandedLayout.Control = direction == .left ? .next : .previous
        Logger.app.info("Gesto: \(direction == .left ? "siguiente" : "anterior", privacy: .public) en la música")
        // El botón se hunde un instante, para que se vea qué ha pasado
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) { model.pressedControl = control }
        Task {
            try? await Task.sleep(for: Self.swipeFlash)
            withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) {
                if model.pressedControl == control { model.pressedControl = nil }
            }
        }
        perform(control)
    }

    // MARK: - Hover

    private func pointerEntered() {
        // La ventana puede medir más que la isla durante una animación: solo cuenta entrar en la isla.
        // Mientras cambia el escritorio (alas recogidas) no se abre. Con "Abrir al pasar el puntero" apagado, solo
        // se abre con el atajo o el gesto
        guard settings.openOnHover, expansion == .closed, tuckedAt == nil, !currentSpaces.isEmpty, pointerIsOverIsland()
        else { return }
        cancelPeek()
        expansion = .peek
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        growWindow()
        if !reduceMotion {
            withAnimation(Self.hoverAnimation) { model.hovering = true }
        }
        // Vibración del trackpad, con .sensoryFeedback en IslandView como hace Atoll
        model.hoverCount += 1

        openTask?.cancel()
        openTask = Task {
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, expansion == .peek else { return }
            open(.pointer)
        }
        watchPointer()
    }

    private func open(_ opening: IslandTab.Opening) {
        cancelPeek()
        expansion = .open
        // Con el puntero se abre en los escritorios; con el atajo o el gesto, en la última pestaña que se eligió. La
        // pestaña y su layout se fijan antes de crecer la ventana, que mide lo que pide la pestaña
        currentTab = IslandTab.opening(opening, last: lastTab, among: IslandTab.allCases)
        model.selectedTab = currentTab
        if let geometry { model.expanded = expandedLayout(for: currentSpaces, geometry: geometry) }
        // Los atajos se leen al abrir: así se ven los cambios hechos en Ajustes sin reiniciar la app
        model.shortcutLabels = focuser.labels(for: currentSpaces.map(\.index))
        growWindow()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.openAnimation) { model.isExpanded = true }
        registerTabKeys(vim: opening.usesVimKeys)
        reportVisibleTab()
        let title = currentTab.title
        Logger.app.info("Isla abierta (\(title, privacy: .public))")
    }

    private func close() {
        openTask?.cancel()
        pointerWatch?.cancel()
        releaseHold()
        let wasOpen = expansion == .open
        expansion = .closed
        reportVisibleTab()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.closeAnimation) {
            model.isExpanded = false
            model.hovering = false
            model.hoveredSpace = nil
            model.pressedSpace = nil
            model.hoveredControl = nil
            model.pressedControl = nil
            model.hoveredRow = nil
            // Un arrastre que no avisó de su salida no deja la bandeja resaltada para la próxima vez
            model.trayTargeted = false
        }
        settleWindow()
        if wasOpen { Logger.app.info("Isla cerrada") }
    }

    // Mientras el puntero está encima se mira dónde está cada 120 ms. Los avisos de salida de macOS fallan en
    // el borde superior de la pantalla, justo donde vive la isla. Con la isla cerrada no corre nada.
    // También repasa la tarjeta bajo el puntero, por si se perdió algún aviso de movimiento.
    private func watchPointer() {
        pointerWatch?.cancel()
        pointerWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pointerCheckInterval)
                guard !Task.isCancelled, expansion != .closed else { return }
                if !pointerIsOverIsland() {
                    if waitingForPointer { continue }
                    // La isla acaba de cambiar de tamaño con el teclado y el puntero quedó fuera: se le da un margen
                    if let tabChangedAt, ContinuousClock.now - tabChangedAt < Self.tabResizeGrace { continue }
                    close()
                    return
                }
                // Abierta con toggle(): desde que llega el puntero, se cierra al salir como con el hover
                waitingForPointer = false
                updateHoveredCard()
            }
        }
    }

    // MARK: - Abrir a petición

    /// El atajo o 3 o 4 dedos hacia abajo en cualquier app: abre la isla aunque el puntero no esté encima, o la
    /// cierra si ya está abierta. Abierta así, espera al puntero y se cierra con Esc, con un clic en otra app o,
    /// si los ajustes lo piden, sola al cabo de unos segundos
    func toggle() {
        if expansion == .open { return close() }
        // Mientras cambia el escritorio no se abre, igual que con el hover
        guard tuckedAt == nil, !currentSpaces.isEmpty else { return }
        openTask?.cancel()
        releaseHold()
        open(.keyboard)
        waitingForPointer = !pointerIsOverIsland()
        escapeKey = GlobalHotKey.escape { [weak self] in self?.close() }
        // Los clics en la isla son de la app y no llegan aquí: solo los de otras apps
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        watchPointer()
        if settings.autoHide { scheduleAutoHide(after: .seconds(settings.autoHideDelay)) }
    }

    // Solo si el puntero no ha llegado a la isla: si está encima, quizá vaya a pulsar una tarjeta
    private func scheduleAutoHide(after delay: Duration) {
        autoHideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, waitingForPointer else { return }
            Logger.app.info("Isla: se oculta sola")
            close()
        }
    }

    private func releaseHold() {
        waitingForPointer = false
        escapeKey = nil
        // Las teclas de las pestañas solo se tienen mientras la isla está abierta: no se le quitan a las demás apps
        tabKeys = []
        vimKeys = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // La isla visible, no la ventana (que mide más por la sombra). El píxel superior de la pantalla cuenta como dentro
    private func pointerIsOverIsland() -> Bool {
        guard let geometry else { return false }
        let island = geometry.windowFrame(width: model.islandWidth, height: model.islandHeight)
        return island.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Pestañas

    // ⌥← y ⌥→ pasan a la pestaña anterior o a la siguiente con la isla abierta, también con el hover; abierta con el
    // teclado o el gesto, además h y l. Se sueltan todas en releaseHold()
    private func registerTabKeys(vim: Bool) {
        // Primero se sueltan las anteriores: registrar dos veces la misma combinación falla
        tabKeys = []
        vimKeys = []
        let arrows = [(kVK_LeftArrow, IslandTab.Step.previous), (kVK_RightArrow, .next)]
        tabKeys = arrows.compactMap { key, step in
            GlobalHotKey(keyCode: key, modifiers: optionKey) { [weak self] in self?.step(step) }
        }
        if vim {
            vimKeys = Self.vimTabKeys.compactMap { key, step in
                GlobalHotKey(keyCode: key, modifiers: 0) { [weak self] in self?.step(step) }
            }
        }
        // Una tecla que otra app ya tiene (o que el usuario eligió para abrir la isla) no se registra: que se sepa
        let expected = arrows.count + (vim ? Self.vimTabKeys.count : 0)
        let registered = tabKeys.count + vimKeys.count
        if registered < expected {
            Logger.app.info("Pestañas: solo se registraron \(registered) de \(expected) teclas")
        }
    }

    private func step(_ step: IslandTab.Step) {
        select(currentTab.stepping(step, among: IslandTab.allCases))
    }

    /// Cambia de pestaña con la isla abierta. La ventana crece antes de animar y se ajusta después, como siempre,
    /// porque cada pestaña mide lo suyo. Se recuerda para abrir con el atajo o el gesto
    private func select(_ tab: IslandTab) {
        guard expansion == .open, let geometry else { return }
        lastTab = tab
        // Usarla es actividad: la isla abierta con el atajo no se oculta sola mientras se cambia de pestaña
        if autoHideTask != nil, settings.autoHide {
            autoHideTask?.cancel()
            scheduleAutoHide(after: .seconds(settings.autoHideDelay))
        }
        guard tab != currentTab else { return }
        currentTab = tab
        tabChangedAt = .now
        reportVisibleTab()
        growWindow()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.tabAnimation) {
            model.selectedTab = tab
            model.expanded = expandedLayout(for: currentSpaces, geometry: geometry)
            model.hoveredSpace = nil
            model.hoveredControl = nil
            model.hoveredRow = nil
        }
        settleWindow()
        Logger.app.info("Isla: pestaña \(tab.title, privacy: .public)")
    }

    /// Una novedad en una pestaña: un punto en su píldora y su ícono en la isla cerrada. nil la quita
    func setBadge(_ badge: TabBadge?, for tab: IslandTab) {
        guard tabBadges[tab] != badge else { return }
        tabBadges[tab] = badge
        apply(spaces: currentSpaces, failed: currentFailed)
    }

    // MARK: - Tarjetas

    // El puntero en coordenadas de la isla abierta, con el origen arriba a la izquierda, como las dibuja SwiftUI.
    // Sale de la geometría de la isla en pantalla y no de onHover, que no es fiable en un panel que nunca se activa.
    private func pointerInOpenIsland() -> (point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat)? {
        guard expansion == .open, let geometry else { return nil }
        let island = geometry.windowFrame(width: model.islandWidth, height: model.islandHeight)
        let pointer = NSEvent.mouseLocation
        return (CGPoint(x: pointer.x - island.minX, y: island.maxY - pointer.y), island.width, geometry.notch.height)
    }

    private func spaceUnderPointer() -> SpaceSummary? {
        guard let (point, islandWidth, topHeight) = pointerInOpenIsland(),
              let index = model.expanded.cardIndex(at: point, islandWidth: islandWidth, topHeight: topHeight) else {
            return nil
        }
        return model.expanded.spaces[index]
    }

    // Los botones de la música y el de mantener despierto
    private func controlUnderPointer() -> IslandExpandedLayout.Control? {
        guard let (point, islandWidth, topHeight) = pointerInOpenIsland() else { return nil }
        if let control = model.expanded.control(at: point, islandWidth: islandWidth, topHeight: topHeight) { return control }
        if let control = model.expanded.calendarControl(
            at: point, islandWidth: islandWidth, topHeight: topHeight, access: model.calendar?.access ?? .notDetermined,
            joinable: model.calendar?.items.map { $0.event.joinURL != nil } ?? []
        ) { return .calendar(control) }
        if let shown = model.clipboard, let control = model.expanded.clipboardControl(
            at: point, islandWidth: islandWidth, topHeight: topHeight, mode: shown.mode, state: shown.state,
            entryCount: shown.rows.count, swatchCount: shown.colors.count
        ) { return .clipboard(control) }
        if let control = model.expanded.trayControl(
            at: point, islandWidth: islandWidth, topHeight: topHeight, ids: model.tray?.items.map(\.id) ?? []
        ) { return .tray(control) }
        return model.expanded.moduleControl(
            at: point, islandWidth: islandWidth, topHeight: topHeight, rows: model.moduleRows
        ).map { .module($0) }
    }

    // La fila de Puertos o Docker bajo el puntero: ahí se ven sus botones
    private func moduleRowUnderPointer() -> String? {
        guard let (point, islandWidth, topHeight) = pointerInOpenIsland() else { return nil }
        return model.expanded.moduleRow(
            at: point, islandWidth: islandWidth, topHeight: topHeight, rows: model.moduleRows
        )?.row.id
    }

    // Solo se iluminan las tarjetas a las que se puede ir, y los botones
    private func updateHoveredCard() {
        let hovered = spaceUnderPointer().flatMap { model.canPress($0) ? $0.index : nil }
        let control = controlUnderPointer()
        let row = moduleRowUnderPointer()
        guard hovered != model.hoveredSpace || control != model.hoveredControl || row != model.hoveredRow else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) {
            model.hoveredSpace = hovered
            model.hoveredControl = control
            model.hoveredRow = row
        }
    }

    /// Pulsar una tarjeta o un botón lo hunde. Devuelve false si el clic no cae en ninguno, y entonces
    /// se abre el menú
    private func pressCard() -> Bool {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let control = controlUnderPointer() {
            withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) {
                model.hoveredControl = control
                model.pressedControl = control
            }
            return true
        }
        guard let space = spaceUnderPointer() else { return false }
        guard model.canPress(space) else { return true }
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) {
            model.hoveredSpace = space.index
            model.pressedSpace = space.index
        }
        return true
    }

    // Como un botón: la acción llega al soltar, y solo si el puntero sigue en la misma tarjeta o el mismo botón
    private func releaseCard() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let pressed = model.pressedControl {
            let control = controlUnderPointer()
            withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) { model.pressedControl = nil }
            if control == pressed { perform(pressed) }
            return
        }
        guard let pressed = model.pressedSpace else { return }
        let space = spaceUnderPointer()
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) { model.pressedSpace = nil }
        guard let space, space.index == pressed else { return }
        switchTo(space)
    }

    private func perform(_ control: IslandExpandedLayout.Control) {
        // Sin el payload de los módulos: la fila de un proyecto de Compose lleva el nombre de la carpeta del usuario
        if case .module(let module) = control {
            Logger.app.info("Clic: módulo \(module.module.rawValue, privacy: .public) \(module.action.rawValue, privacy: .public)")
        } else if case .tray(let control) = control {
            // Sin el identificador, que apunta a un archivo
            Logger.app.info("Clic: bandeja \(control.isRemove ? "quitar" : "archivo", privacy: .public)")
        } else {
            Logger.app.info("Clic: \(String(describing: control), privacy: .public)")
        }
        switch control {
        case .tab(let tab): select(tab)
        case .module(let control): perform(module: control)
        case .calendar(let control): perform(calendar: control)
        case .clipboard(let control): perform(clipboard: control)
        case .tray(let control): perform(tray: control)
        case .keepAwake: keepAwake.toggle()
        case .settings:
            close()
            onOpenSettings?(nil)
        case .pomodoroPlayPause: pomodoro.toggle()
        case .pomodoroSkip: pomodoro.skip()
        case .pomodoroStop: pomodoro.stop()
        case .playPause: media.togglePlayPause()
        case .next: media.nextTrack()
        case .previous: media.previousTrack()
        case .artwork:
            close()
            media.openSource()
        }
    }

    // Cambiar de modo, copiar una copia o una muestra, borrar el historial y las herramientas dejan la isla abierta (el resultado se
    // dice en la cabecera del módulo). El cuentagotas y lo que abre un aviso del sistema o Ajustes del Sistema la cierran: lo de
    // encima necesita el puntero
    private func perform(clipboard control: ClipboardControl) {
        switch control {
        case .mode(let mode): clipboard.setMode(mode)
        case .clear: clipboard.clearHistory()
        case .entry(let index):
            // Por el identificador de la fila que se dibujó, no por la posición
            if let shown = model.clipboard?.rows, shown.indices.contains(index) { clipboard.copy(entryID: shown[index].id) }
        case .tool(let tool): clipboard.run(tool)
        case .swatch(let index): clipboard.copy(swatchAt: index)
        case .picker:
            close()
            clipboard.pickColor()
        case .access:
            close()
            clipboard.requestAccess()
        }
    }

    // Un clic en un archivo lo muestra en el Finder (la isla se cierra: el Finder sale por encima); la «×» lo quita de la bandeja. Los
    // que faltan no hacen nada. Arrastrar un archivo hacia otra app no pasa por aquí: lo empieza el hosting
    private func perform(tray control: TrayControl) {
        switch control {
        case .remove(let id): tray.remove(id: id)
        case .item(let id):
            guard let url = tray.url(for: id) else { return }
            close()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Arrastrar archivos

    /// Con el puntero pulsando un archivo de la bandeja y moviéndose, el hosting pide qué arrastrar: ese archivo si todavía existe. Se
    /// entrega como copia (el hosting solo ofrece `.copy`: la bandeja guarda referencias, y mover el original no es cosa suya)
    private func dragOutURLs() -> [URL] {
        // También pulsando la «×»: quien pulsa en la esquina del ícono y se mueve quiere arrastrarlo, no quitarlo
        guard case .tray(let control) = model.pressedControl else { return [] }
        let id: String
        switch control {
        case .item(let itemID), .remove(let itemID): id = itemID
        }
        guard let url = tray.url(for: id) else { return [] }
        // Con el arrastre empezado, el botón soltado ya no llega a la isla: la pulsación se da por terminada
        model.pressedControl = nil
        return [url]
    }

    /// Un archivo arrastrado de otra app entra en la isla (o se mueve sobre ella): se abre en Utilidades, donde está la bandeja, y esta se
    /// resalta. Con el arrastre en marcha no llegan avisos de puntero, así que la apertura es de aquí, no del hover. Devuelve si lo acepta
    private func fileDragOver(requiringPointer: Bool = true) -> Bool {
        // La ventana mide más que la isla (la sombra, y 1,4 s más tras cerrarse): solo cuenta el arrastre sobre la isla visible. Sin
        // esto, un arrastre sobre la parte transparente la abriría y `watchPointer` la cerraría 120 ms después, una y otra vez
        guard !requiringPointer || pointerIsOverIsland() else {
            fileDragLeft()
            return false
        }
        switch expansion {
        case .closed, .peek:
            // Mientras cambia el escritorio no se abre, igual que con el hover
            guard tuckedAt == nil, !currentSpaces.isEmpty else { return false }
            openTask?.cancel()
            open(.drop)
            // Se cierra al salir el puntero, como con el hover
            watchPointer()
        case .open:
            if currentTab != .utilities {
                // Pasar a Utilidades por un arrastre no cambia la «última pestaña usada» del atajo y el gesto
                let previous = lastTab
                select(.utilities)
                lastTab = previous
            }
        }
        if !model.trayTargeted { withAnimation(Self.cardAnimation) { model.trayTargeted = true } }
        return true
    }

    private func fileDragLeft() {
        guard model.trayTargeted else { return }
        withAnimation(Self.cardAnimation) { model.trayTargeted = false }
    }

    private func fileDropped(_ urls: [URL]) -> Bool {
        fileDragLeft()
        // Soltar sobre la parte transparente de la ventana no cuenta: no se ve la isla
        guard pointerIsOverIsland() else { return false }
        return tray.add(urls: urls) > 0
    }

    /// Un color elegido con el cuentagotas: la isla cerrada dice que ya está copiado
    private func colorCopied(_ hex: String) {
        announce(IslandNotice(symbol: "eyedropper", tone: .ok, title: hex, subtitle: "Color copiado"), failed: false, leavesTrace: false)
    }

    // Elegir un día o pasar de semana deja la isla abierta; abrir Calendario, unirse a una videollamada y abrir Ajustes del Sistema la
    // cierran, porque la otra app sale por encima. «Unirse» lee el evento antes de cerrar: al cerrarse, la tira vuelve a hoy
    private func perform(calendar control: CalendarControl) {
        switch control {
        case .day(let index): calendar.select(dayAt: index)
        case .previousWeek: calendar.shiftWeek(-1)
        case .nextWeek: calendar.shiftWeek(1)
        case .event:
            close()
            CalendarStore.openCalendarApp()
        case .join(let index):
            // El enlace de lo que se dibujó, no de la lista de ahora: entre el dibujo y el clic pudo cambiar
            if let url = model.calendar?.items[safe: index]?.event.joinURL { calendar.join(url) }
            close()
        case .access:
            let needsPrompt = calendar.access == .notDetermined
            close()
            if needsPrompt {
                // El aviso del sistema pide el permiso. Es el usuario quien lo concede
                Task { await calendar.requestAccess() }
            } else {
                calendar.openPrivacySettings()
            }
        }
    }

    // Abrir en el navegador y lo que pregunta antes (cerrar un proceso, parar un contenedor) cierran la isla: la pregunta
    // sale por encima y el puntero sale de la isla. Ir a una sesión de Claude y «Conectar» (que abre Ajustes) también. Lo demás
    // (copiar, reiniciar, iniciar, ver los parados) la deja abierta
    // DevTools resuelve el proceso o el contenedor al llamarlo, antes de que la isla se cierre: al cerrarse, los módulos dejan
    // de medir y olvidan lo que tenían
    private func perform(module control: ModuleControl) {
        tools.perform(control)
        switch control.action {
        case .open, .close, .stop, .activate: close()
        case .connect:
            close()
            onOpenSettings?(.developer)
        case .copy, .restart, .start, .showStopped, .hideStopped: break
        }
    }

    private func switchTo(_ space: SpaceSummary) {
        // Ya estás ahí: solo se cierra la isla
        guard !space.isFocused else { return close() }
        switch focuser.readiness(for: space.index) {
        case .noShortcut:
            Logger.app.info("El escritorio \(space.index) no tiene atajo en Ajustes › Teclado › Atajos")
            close()
            // El aviso, cuando la isla ya se ha cerrado
            Task {
                try? await Task.sleep(for: Self.switchDelay)
                onMissingShortcut?()
            }
        case .needsPermission:
            Logger.app.info("Falta el permiso de Accesibilidad para ir al escritorio \(space.index)")
            close()
            focuser.requestPermission()
        case .ready:
            Logger.app.info("Clic: ir al escritorio \(space.index)")
            collapseIntoNotch()
            Task {
                try? await Task.sleep(for: Self.switchDelay)
                if !focuser.focus(space: space.index) {
                    Logger.app.error("No se pudo pulsar el atajo del escritorio \(space.index)")
                }
            }
            // Si el escritorio no llega a cambiar, las alas vuelven solas
            scheduleUntuck(after: Self.switchDelay + Self.tuckTimeout)
        }
    }

    // Cierra la isla y recoge las alas en un solo movimiento: se encoge hasta el notch y, al llegar al
    // escritorio nuevo, las alas salen con su contenido como en cualquier otro cambio (ver occlusionChanged)
    private func collapseIntoNotch() {
        openTask?.cancel()
        pointerWatch?.cancel()
        untuckTask?.cancel()
        releaseHold()
        expansion = .closed
        reportVisibleTab()
        tuckedAt = .now
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.closeAnimation) {
            model.isExpanded = false
            model.hovering = false
            model.hoveredSpace = nil
            model.hoveredControl = nil
            model.wingsTucked = true
        }
        settleWindow()
    }

    // MARK: - Ventana

    // Marco para el estado actual. Cerrada y en reposo mide justo lo que la isla, para no tapar clics.
    // Con el puntero encima, abierta o durante una animación deja sitio a la sombra y a lo que crece.
    private func targetFrame(roomy: Bool = false) -> NSRect? {
        guard let geometry else { return nil }
        switch expansion {
        case .open:
            let expanded = expandedLayout(for: currentSpaces, geometry: geometry)
            return geometry.windowFrame(
                width: expanded.bodyWidth + 2 * IslandView.openTopRadius + 2 * Self.shadowMargin,
                height: expanded.height + Self.shadowMargin
            )
        case .peek, .closed:
            let wing = currentPeek?.widensWings == true ? IslandLayout.trackPeekWingWidth : currentLayout.wingWidth
            let width = geometry.centerWidth + 2 * wing + 2 * IslandView.closedTopRadius
            guard roomy || expansion == .peek else {
                return geometry.windowFrame(width: width, height: geometry.notch.height)
            }
            return geometry.windowFrame(
                width: width + IslandView.hoverGrowth + 2 * Self.shadowMargin,
                height: geometry.notch.height + IslandView.hoverGrowth + Self.shadowMargin
            )
        }
    }

    // Antes de animar, la ventana crece a lo que necesiten el estado anterior y el nuevo
    private func growWindow() {
        guard let frame = targetFrame(roomy: true) else { return }
        panel.setFrame(panel.frame.isEmpty ? frame : panel.frame.union(frame), display: true)
    }

    // Al terminar la animación, la ventana vuelve al marco del estado que haya en ese momento
    private func settleWindow() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let frame = targetFrame() else { return }
            panel.setFrame(frame, display: true)
        }
    }

    // Texto equivalente a la isla ("1 [2] 3 4"): se muestra si no hay espacios y se usa en el log
    nonisolated static func title(for spaces: [SpaceSummary], failed: Bool) -> String {
        if failed { return "YB ⚠︎" }
        if spaces.isEmpty { return "YB" }
        return spaces.map { $0.isFocused ? "[\($0.index)]" : "\($0.index)" }.joined(separator: " ")
    }

    // La pantalla integrada con notch; si no hay ninguna, la principal
    private static func notchScreen() -> NSScreen? {
        NSScreen.withNotch ?? NSScreen.main
    }
}

extension NSScreen {
    /// La pantalla integrada con notch, si está encendida (con la tapa cerrada no aparece)
    static var withNotch: NSScreen? { screens.first { $0.safeAreaInsets.top > 0 } }

    /// El notch medido en esta pantalla, en cualquier Mac y con cualquier escala; uno de reserva si no tiene
    var notchGeometry: NotchGeometry {
        NotchGeometry(
            screenFrame: frame, topLeftArea: auxiliaryTopLeftArea, topRightArea: auxiliaryTopRightArea,
            topInset: safeAreaInsets.top
        )
    }

    /// El UUID de la pantalla, el mismo que da yabai en `--displays`
    var displayUUID: String? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Lo que ocupa la barra de menús; 0 si se oculta sola
    var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}

// Lienzo de tamaño fijo, centrado y pegado arriba, sobre el que SwiftUI dibuja la isla; la ventana solo lo
// recorta. Al cambiar el marco de la ventana el hosting no cambia de tamaño, SwiftUI no se recoloca y la isla
// no se mueve. Si el hosting se estirase con la ventana, durante un fotograma la isla saltaba a la izquierda.
final class IslandContainerView: NSView {
    var canvasSize = CGSize.zero {
        didSet { placeCanvas() }
    }
    /// Quién atiende los archivos que se sueltan sobre la isla
    var dropHandlers: FileDropHandlers?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no se crea desde un archivo") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandlers?.operation(for: sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandlers?.operation(for: sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHandlers?.left() }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHandlers?.left() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropHandlers?.perform(sender) ?? false }

    // AppKit lo llama dentro del propio setFrame de la ventana, así que el lienzo se recoloca a la vez
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        placeCanvas()
    }

    private func placeCanvas() {
        for view in subviews {
            view.frame = NSRect(
                x: (bounds.width - canvasSize.width) / 2,
                y: bounds.height - canvasSize.height,
                width: canvasSize.width,
                height: canvasSize.height
            )
        }
    }
}

// El clic en una tarjeta de la isla abierta lo gestiona IslandController; cualquier otro abre el menú de la app
final class IslandHostingView: NSHostingView<IslandView> {
    var menuOnClick: NSMenu?
    var onPointerEntered: (@MainActor () -> Void)?
    var onPointerMoved: (@MainActor () -> Void)?
    /// Devuelve true si el clic cae en una tarjeta; si no, se abre el menú
    var onPress: (@MainActor () -> Bool)?
    var onRelease: (@MainActor () -> Void)?
    var onScroll: (@MainActor (SideSwipeTracker.Sample) -> Void)?
    /// Pide qué archivos arrastrar desde donde se pulsó (los de la bandeja); vacío si no hay nada que arrastrar
    var onDragOut: (@MainActor () -> [URL])?
    var onDragEnded: (@MainActor () -> Void)? {
        didSet { dragSource.onEnded = onDragEnded }
    }
    /// La fuente de la sesión de arrastre: la sesión no la retiene, y la vista sí
    private let dragSource = TrayDragSource()
    private var trackingArea: NSTrackingArea?
    /// Dónde se pulsó, para saber si el puntero se movió lo bastante como para empezar a arrastrar
    private var pressOrigin: NSPoint?
    private static let dragThreshold: CGFloat = 4

    // La isla vive en un panel que nunca se activa: el primer clic tiene que llegar igualmente
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // La entrada y el movimiento (para la tarjeta bajo el puntero): la salida la vigila IslandController
    // mirando la posición del puntero. `.activeAlways` porque la app nunca es la activa
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved?()
    }

    override func mouseDown(with event: NSEvent) {
        if onPress?() == true {
            pressOrigin = event.locationInWindow
            return
        }
        pressOrigin = nil
        showMenu(for: event)
    }

    // Pulsando un archivo de la bandeja y moviendo el puntero unos puntos empieza el arrastre. Sin ese margen, cada clic sería un
    // arrastre. Una vez empezado, el mouseUp ya no llega aquí: lo recoge la sesión de arrastre
    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= Self.dragThreshold
        else { return }
        pressOrigin = nil
        let urls = onDragOut?() ?? []
        guard !urls.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(NSRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: dragSource)
    }

    // AppKit manda el mouseUp a la vista que recibió el mouseDown, aunque el puntero ya no esté encima
    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        onRelease?()
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    // macOS manda el scroll a la ventana bajo el puntero aunque la app no esté activa. La isla no desplaza nada:
    // solo sirve para el gesto de lado sobre la música
    override func scrollWheel(with event: NSEvent) { onScroll?(SideSwipeTracker.Sample(event)) }

    private func showMenu(for event: NSEvent) {
        guard let menuOnClick else { return }
        NSMenu.popUpContextMenu(menuOnClick, with: event, for: self)
    }
}

// Lo que se arrastra desde la isla es siempre una copia: la bandeja guarda referencias, y que el destino mueva o borre el original
// (el Finder en el mismo volumen, la papelera del Dock) no es lo que se pidió al arrastrar
// NSHostingView ya es NSDraggingSource y no deja sobrescribirlo (lo de SwiftUI), así que la sesión tiene su propia fuente
@MainActor
final class TrayDragSource: NSObject, NSDraggingSource {
    var onEnded: (@MainActor () -> Void)?
    /// Lo único que se ofrece al destino: copiar. Ni `.move` ni `.delete`, que dejarían al Finder mover el original o a la papelera del
    /// Dock borrarlo
    static let operation: NSDragOperation = .copy

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operation
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded?()
    }
}

/// Lo que hace la isla con un archivo que se arrastra sobre ella
struct FileDropHandlers {
    /// El arrastre entra o se mueve sobre la isla: devuelve si lo acepta
    var over: @MainActor () -> Bool
    var left: @MainActor () -> Void
    var dropped: @MainActor ([URL]) -> Bool

    /// Los archivos locales del arrastre. Solo se lee el portapapeles del propio arrastre (no el general), que es del usuario
    @MainActor
    static func fileURLs(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Lo que arrastra la propia isla (un archivo de la bandeja) no se acepta de vuelta: no se duplica
    @MainActor
    static func isOwn(_ info: NSDraggingInfo) -> Bool { info.draggingSource is TrayDragSource }

    @MainActor
    func operation(for info: NSDraggingInfo) -> NSDragOperation {
        guard !Self.isOwn(info),
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return over() ? .copy : []
    }

    @MainActor
    func perform(_ info: NSDraggingInfo) -> Bool {
        guard !Self.isOwn(info) else { return false }
        let urls = Self.fileURLs(in: info)
        return urls.isEmpty ? false : dropped(urls)
    }
}

private extension SideSwipeTracker.Sample {
    init(_ event: NSEvent) {
        let phase: Phase
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            phase = .began
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            phase = .ended
        } else if event.phase.isEmpty {
            phase = .none
        } else {
            phase = .changed
        }
        self.init(
            phase: phase,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            isMomentum: !event.momentumPhase.isEmpty
        )
    }
}

#if DEBUG
extension IslandController {
    /// yabaibar://abrir?tab=desarrollador: abre la isla en esa pestaña como con ⌥I, pero sin ocultarse sola, para medir
    /// lo que consume con la pestaña a la vista. Se cierra con yabaibar://cerrar, con Esc o con un clic en otra app
    func debugOpen(tab: IslandTab) {
        guard expansion == .closed else { return }
        lastTab = tab
        toggle()
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    func debugClose() {
        if expansion == .open { close() }
    }

    /// yabaibar://bandeja-prueba: lo que se puede comprobar de soltar un archivo sin soltar uno de verdad. Dice en el log qué tipos de
    /// arrastre tienen registrados el contenedor y el hosting de SwiftUI (si el hosting registrara `fileURL`, se llevaría el arrastre
    /// y el contenedor no lo vería), hace lo que haría un arrastre que entra en la isla (abrirla en Utilidades y resaltar la bandeja) y,
    /// pasado un momento, lo que hace al salir
    func debugTrayDrag() {
        let types = { (view: NSView) in view.registeredDraggedTypes.map(\.rawValue).sorted().joined(separator: ",") }
        let containerTypes = types(container)
        let hostingTypes = types(hosting)
        Logger.app.info("Bandeja (DEBUG): tipos registrados: contenedor [\(containerTypes, privacy: .public)], hosting [\(hostingTypes, privacy: .public)]")
        let accepted = fileDragOver(requiringPointer: false)
        let tab = currentTab.title
        Logger.app.info("Bandeja (DEBUG): arrastre aceptado=\(accepted, privacy: .public), pestaña \(tab, privacy: .public), abierta=\(self.expansion == .open, privacy: .public), resaltada=\(self.model.trayTargeted, privacy: .public)")
        Task {
            try? await Task.sleep(for: .seconds(2))
            fileDragLeft()
            Logger.app.info("Bandeja (DEBUG): el arrastre salió, resaltada=\(self.model.trayTargeted, privacy: .public)")
        }
    }

    /// Simula cambios de espacio activo muy seguidos, como pasar rápido entre escritorios,
    /// sin tocar los espacios reales. Al terminar vuelve a dibujar el estado real.
    func stressTest(rounds: Int = 40, interval: Duration = .milliseconds(40)) {
        let base = store.spaces
        guard base.count > 1 else { return }
        Task {
            for round in 0..<rounds {
                let focused = base[round % base.count].index
                // Como un cambio real: primero el aviso de macOS (recoge las alas) y luego el contenido
                spaceDidChange()
                apply(spaces: base.map { SpaceSummary(index: $0.index, isFocused: $0.index == focused, apps: $0.apps) }, failed: false)
                try? await Task.sleep(for: interval)
            }
            render()
            Logger.app.info("Prueba de estrés terminada: \(rounds) cambios")
        }
    }

    /// Guarda la isla como PNG ampliado y sobre un fondo gris, para revisarla sin mirar la pantalla.
    /// Con `expanded`, la dibuja abierta un instante (se restaura enseguida, sin llegar a la pantalla);
    /// con `hoveringCard`, además con el puntero sobre la primera tarjeta inactiva a la que se puede ir.
    /// Con `peek`, la isla cerrada con ese aviso (el de canción nueva, solo si suena algo). Con `simulating`, la
    /// isla con el notch y la pantalla de otro Mac, para revisarla sin tenerlo. Con `tab`, la isla abierta en esa
    /// pestaña; con `badges`, con novedades en Utilidades y Desarrollador (su ícono en la isla cerrada y el punto en
    /// las píldoras). Las barras de la música y el anillo del Pomodoro son capas de Core Animation y ImageRenderer no
    /// las dibuja
    func saveSnapshot(
        expanded: Bool = false, hoveringCard: Bool = false, peek: IslandPeek? = nil,
        simulating simulated: (screen: CGSize, notch: CGSize)? = nil, tab: IslandTab? = nil, badges: Bool = false,
        hoveringRowOf hoveredModule: ModuleID? = nil, trayTargeted: Bool = false
    ) {
        let wasExpanded = model.isExpanded
        let wasHovered = model.hoveredSpace
        let wasPeek = model.peek
        let wasGeometry = (model.centerWidth, model.height, model.expanded)
        let wasTab = model.selectedTab
        let wasBadges = model.tabBadges
        let wasLayout = model.layout
        let wasCurrentLayout = currentLayout
        let wasSystem = model.system
        let wasModules = model.moduleContent
        let wasHoveredRow = model.hoveredRow
        let wasCalendar = model.calendar
        let wasClipboard = model.clipboard
        let wasTray = (model.tray, model.trayTargeted)
        // Los monitores solo corren con la pestaña a la vista: el snapshot enseña la última medida que haya
        if tab == .developer {
            model.system = tools.system.snapshot
            model.moduleContent = tools.rowsContent()
            // La primera fila de ese módulo, con el puntero encima: se ven sus botones
            if let hoveredModule { model.hoveredRow = model.moduleContent[hoveredModule]?.rows.first?.id }
        }
        // El calendario se dibuja con lo que haya ahora, sin esperar al seguimiento
        if (tab ?? model.selectedTab) == .utilities {
            model.calendar = calendar.snapshot
            model.clipboard = clipboard.snapshotForImage
            model.tray = tray.snapshotForImage
            model.trayTargeted = trayTargeted
        }
        // Con novedades, las alas son más anchas: el layout de la isla abierta se calcula con ellas, como hace apply()
        if badges {
            let layout = IslandLayout(spaces: currentSpaces, statusItems: statusItems() + [.utilities, .developer])
            currentLayout = layout
            model.layout = layout
            model.tabBadges = [.utilities: .info, .developer: .attention]
        }
        let geometry = simulated.map { NotchGeometry.centered(screen: $0.screen, notch: $0.notch) } ?? self.geometry
        if let simulated, let geometry {
            model.centerWidth = geometry.centerWidth
            model.height = geometry.notch.height
            let notch = "\(Int(simulated.notch.width)) × \(Int(simulated.notch.height)) pt"
            let screen = "\(Int(simulated.screen.width)) × \(Int(simulated.screen.height))"
            Logger.app.info("Snapshot simulado: notch de \(notch, privacy: .public) en \(screen, privacy: .public)")
        }
        if let geometry, simulated != nil || tab != nil || badges {
            model.expanded = expandedLayout(
                for: currentSpaces, geometry: geometry, screenWidth: simulated?.screen.width, tab: tab
            )
        }
        if let tab { model.selectedTab = tab }
        model.isExpanded = expanded || hoveringCard || wasExpanded || tab != nil
        if model.isExpanded { model.shortcutLabels = focuser.labels(for: currentSpaces.map(\.index)) }
        if hoveringCard {
            model.hoveredSpace = currentSpaces.first { !$0.isFocused && model.canSwitch(to: $0) }?.index
        }
        if let peek, peek != .track || model.nowPlaying != nil { model.peek = peek }
        defer {
            model.isExpanded = wasExpanded
            model.hoveredSpace = wasHovered
            model.peek = wasPeek
            model.selectedTab = wasTab
            model.tabBadges = wasBadges
            model.layout = wasLayout
            currentLayout = wasCurrentLayout
            model.system = wasSystem
            model.moduleContent = wasModules
            model.hoveredRow = wasHoveredRow
            model.calendar = wasCalendar
            model.clipboard = wasClipboard
            (model.tray, model.trayTargeted) = wasTray
            (model.centerWidth, model.height, model.expanded) = wasGeometry
        }
        let size = CGSize(width: model.islandWidth + 2 * Self.shadowMargin, height: model.islandHeight + Self.shadowMargin)
        let content = hosting.rootView
            .frame(width: size.width, height: size.height)
            .padding(16)
            .background(Color(white: 0.17))
        let zoom: CGFloat = 4
        let renderer = ImageRenderer(content: content)
        renderer.scale = zoom
        // Se dibuja en un mapa de bits RGB de 8 bits: guardar directamente la salida de ImageRenderer
        // (en un espacio de color extendido) dejaba los colores apagados en el PNG
        guard let image = renderer.nsImage,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * zoom), pixelsHigh: Int(image.size.height * zoom),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else {
            Logger.app.error("Snapshot: no se pudo dibujar la isla")
            return
        }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }

        let directory = URL.cachesDirectory.appending(path: "com.jerickdev.yabaibar")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appending(path: "bar.png"))
            Logger.app.info("Snapshot guardado: isla de \(Int(size.width))×\(Int(size.height)) pt")
        } catch {
            Logger.app.error("Snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
