import Foundation
import Observation
import SwiftUI

// Ajustes del usuario, guardados en UserDefaults: la velocidad de las alas al cambiar de escritorio, cómo se abre
// la isla (con el puntero, con el atajo, si se oculta sola) y qué música muestra.
@MainActor
@Observable
final class AppSettings {
    static let defaultAutoHideDelay = 3
    static let autoHideDelays = 1...10

    var switchSpeed: SwitchSpeed {
        didSet { defaults.set(switchSpeed.rawValue, forKey: Key.switchSpeed) }
    }

    /// nil: la isla no tiene atajo y solo se abre a petición con el gesto. Se guarda vacío, para distinguirlo de
    /// no haberlo cambiado nunca
    var toggleShortcut: HotKeyShortcut? {
        didSet { Self.save(toggleShortcut, forKey: Key.toggleShortcut, in: defaults) }
    }

    /// El atajo que inicia, pausa o reanuda el Pomodoro desde cualquier app; nil, sin atajo
    var pomodoroShortcut: HotKeyShortcut? {
        didSet { Self.save(pomodoroShortcut, forKey: Key.pomodoroShortcut, in: defaults) }
    }

    /// Abierta con el atajo o con el gesto, se oculta sola si el puntero no llega a la isla
    var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: Key.autoHide) }
    }

    /// En segundos
    var autoHideDelay: Int {
        didSet { defaults.set(autoHideDelay, forKey: Key.autoHideDelay) }
    }

    /// YabaiBar añade al arrancar las señales de yabai que la refrescan (ver YabaiSignals)
    var autoYabaiSignals: Bool {
        didSet { defaults.set(autoYabaiSignals, forKey: Key.autoYabaiSignals) }
    }

    /// Los escritorios nuevos del 1 al 9 reciben solos su atajo «Ir al escritorio N» (ver DesktopShortcutAssistant).
    /// Apagado hasta que el usuario elige «Añadir siempre» o lo activa en Ajustes
    var autoDesktopShortcuts: Bool {
        didSet { defaults.set(autoDesktopShortcuts, forKey: Key.autoDesktopShortcuts) }
    }

    /// "Primeros pasos" se abre sola solo la primera vez
    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }

    /// Si no, la isla solo se abre con el atajo o el gesto
    var openOnHover: Bool {
        didSet { defaults.set(openOnHover, forKey: Key.openOnHover) }
    }

    /// La franja "Ahora suena" de la isla abierta. Apagada, el adaptador no corre
    var showNowPlaying: Bool {
        didSet { defaults.set(showNowPlaying, forKey: Key.showNowPlaying) }
    }

    var nowPlayingSource: NowPlayingSource {
        didSet { defaults.set(nowPlayingSource.rawValue, forKey: Key.nowPlayingSource) }
    }

    /// Las barras al final del ala derecha de la isla cerrada mientras hay música
    var showMusicBars: Bool {
        didSet { defaults.set(showMusicBars, forKey: Key.showMusicBars) }
    }

    /// Al cambiar de canción, la isla cerrada enseña unos segundos la carátula y el título
    var announceTracks: Bool {
        didSet { defaults.set(announceTracks, forKey: Key.announceTracks) }
    }

    /// Avisos al enchufar o desenchufar el cargador y con poca batería
    var batteryAlerts: Bool {
        didSet { defaults.set(batteryAlerts, forKey: Key.batteryAlerts) }
    }

    /// El botón de mantener despierto en la isla abierta. Al apagarlo, el Mac deja de mantenerse despierto
    var keepAwakeButton: Bool {
        didSet { defaults.set(keepAwakeButton, forKey: Key.keepAwakeButton) }
    }

    // MARK: - Pomodoro

    static let focusMinutes = 5...90
    static let shortBreakMinutes = 1...30
    static let longBreakMinutes = 5...60
    static let pomodoroRoundsRange = 2...8
    static let dailyGoals = 1...16
    /// Segundos antes del final para el aviso; 0, sin aviso
    static let pomodoroWarnings = [0, 10, 15, 30, 60]

    /// La parte del Pomodoro en la pestaña Utilidades de la isla abierta. Al apagarlo se termina la sesión
    var showPomodoro: Bool {
        didSet { defaults.set(showPomodoro, forKey: Key.showPomodoro) }
    }

    var pomodoroFocusMinutes: Int {
        didSet { defaults.set(pomodoroFocusMinutes, forKey: Key.pomodoroFocusMinutes) }
    }

    var pomodoroShortBreakMinutes: Int {
        didSet { defaults.set(pomodoroShortBreakMinutes, forKey: Key.pomodoroShortBreakMinutes) }
    }

    var pomodoroLongBreakMinutes: Int {
        didSet { defaults.set(pomodoroLongBreakMinutes, forKey: Key.pomodoroLongBreakMinutes) }
    }

    /// Cada cuántos focos toca el descanso largo
    var pomodoroRounds: Int {
        didSet { defaults.set(pomodoroRounds, forKey: Key.pomodoroRounds) }
    }

    var pomodoroAutoStartBreaks: Bool {
        didSet { defaults.set(pomodoroAutoStartBreaks, forKey: Key.pomodoroAutoStartBreaks) }
    }

    var pomodoroAutoStartFocus: Bool {
        didSet { defaults.set(pomodoroAutoStartFocus, forKey: Key.pomodoroAutoStartFocus) }
    }

    /// Segundos antes del final para el aviso; 0, sin aviso
    var pomodoroWarning: Int {
        didSet { defaults.set(pomodoroWarning, forKey: Key.pomodoroWarning) }
    }

    var pomodoroDailyGoal: Int {
        didSet { defaults.set(pomodoroDailyGoal, forKey: Key.pomodoroDailyGoal) }
    }

    /// El anillo de progreso al final del ala derecha de la isla cerrada, mientras hay sesión
    var showPomodoroRing: Bool {
        didSet { defaults.set(showPomodoroRing, forKey: Key.showPomodoroRing) }
    }

    /// El panel de yabai (las ventanas del escritorio activo y sus botones) debajo de las tarjetas de Escritorios. Apagado, no se ve ni
    /// consulta nada
    var showDesktopPanel: Bool {
        didSet { defaults.set(showDesktopPanel, forKey: Key.showDesktopPanel) }
    }

    /// Cambiar de escritorio con un clic en su tarjeta usa `space --focus` de yabai (al instante, sin la animación de macOS) en vez del
    /// atajo ⌥N. Necesita la scripting addition: sin ella se sigue usando el atajo
    var instantSwitch: Bool {
        didSet { defaults.set(instantSwitch, forKey: Key.instantSwitch) }
    }

    /// La distribución que el usuario eligió para cada escritorio (índice → bsp, stack o float), que yabai pierde al reiniciarse y la app
    /// vuelve a poner
    var rememberedLayouts: [String: String] {
        didSet { defaults.set(rememberedLayouts, forKey: Key.rememberedLayouts) }
    }

    /// Las apps (por su nombre) que siempre flotan: una regla de yabai que la app vuelve a añadir cuando yabai se reinicia
    var floatApps: [String] {
        didSet { defaults.set(floatApps, forKey: Key.floatApps) }
    }

    /// El módulo Docker de la pestaña Desarrollador. Apagado, no se ve ni consulta nada
    var showDocker: Bool {
        didSet { defaults.set(showDocker, forKey: Key.showDocker) }
    }

    /// Un aviso en la isla cerrada cuando una sesión de Claude Code termina tras trabajar más de 30 s
    var claudeNotifyFinished: Bool {
        didSet { defaults.set(claudeNotifyFinished, forKey: Key.claudeNotifyFinished) }
    }

    /// El módulo Git de la pestaña Desarrollador y sus avisos. Apagado, no se vigila ningún repositorio
    var showGit: Bool {
        didSet { defaults.set(showGit, forKey: Key.showGit) }
    }

    /// Preguntar a GitHub con `gh` (releases, CI y PR). Apagado, solo se mira lo que git sabe en local
    var gitUseGitHub: Bool {
        didSet { defaults.set(gitUseGitHub, forKey: Key.gitUseGitHub) }
    }

    /// Las carpetas que se vigilan además de las de las sesiones de Claude Code abiertas
    var gitFolders: [String] {
        didSet { defaults.set(gitFolders, forKey: Key.gitFolders) }
    }

    static let gitUnpushedMinutesOptions = [10, 15, 30, 60, 120]

    /// Los avisos de la isla cerrada cuando un comando largo de la terminal termina (los manda `yb`, ver ZshHook)
    var terminalNotices: Bool {
        didSet { defaults.set(terminalNotices, forKey: Key.terminalNotices) }
    }

    static let terminalMinSecondsOptions = [5, 10, 20, 30, 60, 120]

    /// El historial del portapapeles de la pestaña Utilidades. Apagado hasta que el usuario lo enciende: macOS pregunta antes de dejar
    /// que una app lea el portapapeles sin que pegues, y el historial apunta todo lo que copias
    var clipboardHistory: Bool {
        didSet { defaults.set(clipboardHistory, forKey: Key.clipboardHistory) }
    }

    /// Guardar el historial en disco (en Application Support, solo legible por el usuario). Apagado, solo vive en memoria
    var clipboardPersist: Bool {
        didSet { defaults.set(clipboardPersist, forKey: Key.clipboardPersist) }
    }

    /// Las apps (por su identificador) de las que no se guarda nada. Por defecto, los gestores de contraseñas conocidos
    var clipboardIgnoredApps: [String] {
        didSet { defaults.set(clipboardIgnoredApps, forKey: Key.clipboardIgnoredApps) }
    }

    /// Las últimas muestras del selector de color, en hexadecimal
    var clipboardColors: [String] {
        didSet { defaults.set(clipboardColors, forKey: Key.clipboardColors) }
    }

    /// Un aviso en la isla cerrada 5 minutos antes de cada evento del calendario
    var calendarNotice: Bool {
        didSet { defaults.set(calendarNotice, forKey: Key.calendarNotice) }
    }

    /// Los calendarios (por su identificador) que no se leen. Vacío: todos
    var calendarExcluded: [String] {
        didSet { defaults.set(calendarExcluded, forKey: Key.calendarExcluded) }
    }

    /// Lo mínimo que tiene que tardar un comando para avisar. Además del `YB_AVISO_MIN` de la shell: manda el más alto
    var terminalMinSeconds: Int {
        didSet { defaults.set(terminalMinSeconds, forKey: Key.terminalMinSeconds) }
    }

    /// Avisar aunque la app de la terminal esté delante. Apagado, un comando que termina mientras lo miras no sale en la isla
    /// (sí en el módulo Avisos)
    var terminalWhenFrontmost: Bool {
        didSet { defaults.set(terminalWhenFrontmost, forKey: Key.terminalWhenFrontmost) }
    }

    /// Cada aviso de Git, por separado
    var gitNoticeUnpushed: Bool {
        didSet { defaults.set(gitNoticeUnpushed, forKey: Key.gitNoticeUnpushed) }
    }

    /// Los minutos con commits sin subir antes de avisar
    var gitUnpushedMinutes: Int {
        didSet { defaults.set(gitUnpushedMinutes, forKey: Key.gitUnpushedMinutes) }
    }

    var gitNoticeUncommitted: Bool {
        didSet { defaults.set(gitNoticeUncommitted, forKey: Key.gitNoticeUncommitted) }
    }

    var gitNoticeUnreleased: Bool {
        didSet { defaults.set(gitNoticeUnreleased, forKey: Key.gitNoticeUnreleased) }
    }

    var gitNoticeCI: Bool {
        didSet { defaults.set(gitNoticeCI, forKey: Key.gitNoticeCI) }
    }

    var gitNoticeSettings: GitNoticeSettings {
        GitNoticeSettings(
            unpushed: gitNoticeUnpushed, unpushedAfter: TimeInterval(gitUnpushedMinutes) * 60, uncommitted: gitNoticeUncommitted,
            unreleased: gitNoticeUnreleased, ci: gitNoticeCI
        )
    }

    static let duckLevels = 20...60

    /// Los sonidos del aviso y del final de cada fase
    var pomodoroSound: Bool {
        didSet { defaults.set(pomodoroSound, forKey: Key.pomodoroSound) }
    }

    /// En el aviso, si suena música, el volumen baja hasta el final de la fase
    var pomodoroDuckMusic: Bool {
        didSet { defaults.set(pomodoroDuckMusic, forKey: Key.pomodoroDuckMusic) }
    }

    /// Hasta qué porcentaje del volumen que había
    var pomodoroDuckLevel: Int {
        didSet { defaults.set(pomodoroDuckLevel, forKey: Key.pomodoroDuckLevel) }
    }

    /// El preset que corresponde a los tiempos; elegir uno cambia los cuatro tiempos de golpe
    var pomodoroPreset: PomodoroPreset {
        get {
            PomodoroPreset.matching(
                focus: pomodoroFocusMinutes, shortBreak: pomodoroShortBreakMinutes,
                longBreak: pomodoroLongBreakMinutes, rounds: pomodoroRounds
            )
        }
        set {
            guard let minutes = newValue.minutes else { return }
            pomodoroFocusMinutes = minutes.focus
            pomodoroShortBreakMinutes = minutes.shortBreak
            pomodoroLongBreakMinutes = minutes.longBreak
            pomodoroRounds = minutes.rounds
        }
    }

    var pomodoroDurations: PomodoroDurations {
        PomodoroDurations(
            focus: TimeInterval(pomodoroFocusMinutes * 60), shortBreak: TimeInterval(pomodoroShortBreakMinutes * 60),
            longBreak: TimeInterval(pomodoroLongBreakMinutes * 60), roundsUntilLongBreak: pomodoroRounds
        )
    }

    /// Mientras se graba un atajo nuevo no se escucha el actual: Carbon se lo quedaría antes que la ventana
    var isRecordingShortcut = false
    /// Por qué no se pudo registrar cada atajo, para mostrarlo en los ajustes
    var shortcutError: String?
    var pomodoroShortcutError: String?

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let switchSpeed = "switchSpeed"
        static let toggleShortcut = "toggleShortcut"
        static let pomodoroShortcut = "pomodoroShortcut"
        static let autoHide = "autoHide"
        static let autoHideDelay = "autoHideDelay"
        static let openOnHover = "openOnHover"
        static let autoYabaiSignals = "autoYabaiSignals"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let autoDesktopShortcuts = "autoDesktopShortcuts"
        static let showNowPlaying = "showNowPlaying"
        static let nowPlayingSource = "nowPlayingSource"
        static let showMusicBars = "showMusicBars"
        static let announceTracks = "announceTracks"
        static let batteryAlerts = "batteryAlerts"
        static let keepAwakeButton = "keepAwakeButton"
        static let showPomodoro = "showPomodoro"
        static let pomodoroFocusMinutes = "pomodoroFocusMinutes"
        static let pomodoroShortBreakMinutes = "pomodoroShortBreakMinutes"
        static let pomodoroLongBreakMinutes = "pomodoroLongBreakMinutes"
        static let pomodoroRounds = "pomodoroRounds"
        static let pomodoroAutoStartBreaks = "pomodoroAutoStartBreaks"
        static let pomodoroAutoStartFocus = "pomodoroAutoStartFocus"
        static let pomodoroWarning = "pomodoroWarning"
        static let pomodoroDailyGoal = "pomodoroDailyGoal"
        static let showPomodoroRing = "showPomodoroRing"
        static let showDocker = "showDocker"
        static let showDesktopPanel = "showDesktopPanel"
        static let instantSwitch = "instantSwitch"
        static let rememberedLayouts = "rememberedLayouts"
        static let floatApps = "floatApps"
        static let claudeNotifyFinished = "claudeNotifyFinished"
        static let showGit = "showGit"
        static let gitUseGitHub = "gitUseGitHub"
        static let gitFolders = "gitFolders"
        static let gitNoticeUnpushed = "gitNoticeUnpushed"
        static let gitUnpushedMinutes = "gitUnpushedMinutes"
        static let gitNoticeUncommitted = "gitNoticeUncommitted"
        static let gitNoticeUnreleased = "gitNoticeUnreleased"
        static let gitNoticeCI = "gitNoticeCI"
        static let terminalNotices = "terminalNotices"
        static let terminalMinSeconds = "terminalMinSeconds"
        static let terminalWhenFrontmost = "terminalWhenFrontmost"
        static let clipboardHistory = "clipboardHistory"
        static let clipboardPersist = "clipboardPersist"
        static let clipboardIgnoredApps = "clipboardIgnoredApps"
        static let clipboardColors = "clipboardColors"
        static let calendarNotice = "calendarNotice"
        static let calendarExcluded = "calendarExcluded"
        static let pomodoroSound = "pomodoroSound"
        static let pomodoroDuckMusic = "pomodoroDuckMusic"
        static let pomodoroDuckLevel = "pomodoroDuckLevel"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        switchSpeed = defaults.string(forKey: Key.switchSpeed).flatMap(SwitchSpeed.init(rawValue:)) ?? .normal
        toggleShortcut = Self.shortcut(forKey: Key.toggleShortcut, in: defaults, fallback: .defaultToggle)
        pomodoroShortcut = Self.shortcut(forKey: Key.pomodoroShortcut, in: defaults, fallback: .defaultPomodoro)
        autoHide = defaults.object(forKey: Key.autoHide) as? Bool ?? true
        let delay = defaults.object(forKey: Key.autoHideDelay) as? Int ?? Self.defaultAutoHideDelay
        autoHideDelay = Self.autoHideDelays.contains(delay) ? delay : Self.defaultAutoHideDelay
        openOnHover = defaults.object(forKey: Key.openOnHover) as? Bool ?? true
        autoYabaiSignals = defaults.object(forKey: Key.autoYabaiSignals) as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: Key.hasSeenWelcome)
        autoDesktopShortcuts = defaults.bool(forKey: Key.autoDesktopShortcuts)
        showNowPlaying = defaults.object(forKey: Key.showNowPlaying) as? Bool ?? true
        nowPlayingSource = defaults.string(forKey: Key.nowPlayingSource).flatMap(NowPlayingSource.init(rawValue:)) ?? .any
        showMusicBars = defaults.object(forKey: Key.showMusicBars) as? Bool ?? true
        announceTracks = defaults.object(forKey: Key.announceTracks) as? Bool ?? true
        batteryAlerts = defaults.object(forKey: Key.batteryAlerts) as? Bool ?? true
        keepAwakeButton = defaults.object(forKey: Key.keepAwakeButton) as? Bool ?? true
        showPomodoro = defaults.object(forKey: Key.showPomodoro) as? Bool ?? true
        // Lo guardado fuera de su rango vuelve al valor del preset clásico
        let int = { (key: String, range: ClosedRange<Int>, fallback: Int) -> Int in
            (defaults.object(forKey: key) as? Int).flatMap { range.contains($0) ? $0 : nil } ?? fallback
        }
        pomodoroFocusMinutes = int(Key.pomodoroFocusMinutes, Self.focusMinutes, 25)
        pomodoroShortBreakMinutes = int(Key.pomodoroShortBreakMinutes, Self.shortBreakMinutes, 5)
        pomodoroLongBreakMinutes = int(Key.pomodoroLongBreakMinutes, Self.longBreakMinutes, 15)
        pomodoroRounds = int(Key.pomodoroRounds, Self.pomodoroRoundsRange, 4)
        pomodoroAutoStartBreaks = defaults.object(forKey: Key.pomodoroAutoStartBreaks) as? Bool ?? true
        pomodoroAutoStartFocus = defaults.object(forKey: Key.pomodoroAutoStartFocus) as? Bool ?? false
        let warning = defaults.object(forKey: Key.pomodoroWarning) as? Int ?? 30
        pomodoroWarning = Self.pomodoroWarnings.contains(warning) ? warning : 30
        pomodoroDailyGoal = int(Key.pomodoroDailyGoal, Self.dailyGoals, 8)
        showPomodoroRing = defaults.object(forKey: Key.showPomodoroRing) as? Bool ?? true
        showDocker = defaults.object(forKey: Key.showDocker) as? Bool ?? true
        showDesktopPanel = defaults.object(forKey: Key.showDesktopPanel) as? Bool ?? true
        instantSwitch = defaults.object(forKey: Key.instantSwitch) as? Bool ?? false
        rememberedLayouts = defaults.dictionary(forKey: Key.rememberedLayouts) as? [String: String] ?? [:]
        floatApps = (defaults.stringArray(forKey: Key.floatApps) ?? []).compactMap(YabaiRules.clean)
        claudeNotifyFinished = defaults.object(forKey: Key.claudeNotifyFinished) as? Bool ?? false
        showGit = defaults.object(forKey: Key.showGit) as? Bool ?? true
        gitUseGitHub = defaults.object(forKey: Key.gitUseGitHub) as? Bool ?? true
        gitFolders = defaults.stringArray(forKey: Key.gitFolders) ?? []
        gitNoticeUnpushed = defaults.object(forKey: Key.gitNoticeUnpushed) as? Bool ?? true
        let minutes = defaults.object(forKey: Key.gitUnpushedMinutes) as? Int ?? 30
        gitUnpushedMinutes = Self.gitUnpushedMinutesOptions.contains(minutes) ? minutes : 30
        gitNoticeUncommitted = defaults.object(forKey: Key.gitNoticeUncommitted) as? Bool ?? true
        gitNoticeUnreleased = defaults.object(forKey: Key.gitNoticeUnreleased) as? Bool ?? true
        gitNoticeCI = defaults.object(forKey: Key.gitNoticeCI) as? Bool ?? true
        terminalNotices = defaults.object(forKey: Key.terminalNotices) as? Bool ?? true
        let terminalMin = defaults.object(forKey: Key.terminalMinSeconds) as? Int ?? 10
        terminalMinSeconds = Self.terminalMinSecondsOptions.contains(terminalMin) ? terminalMin : 10
        terminalWhenFrontmost = defaults.object(forKey: Key.terminalWhenFrontmost) as? Bool ?? false
        clipboardHistory = defaults.object(forKey: Key.clipboardHistory) as? Bool ?? false
        clipboardPersist = defaults.object(forKey: Key.clipboardPersist) as? Bool ?? false
        clipboardIgnoredApps = defaults.stringArray(forKey: Key.clipboardIgnoredApps) ?? ClipboardFilter.defaultIgnoredApps
        clipboardColors = defaults.stringArray(forKey: Key.clipboardColors) ?? []
        calendarNotice = defaults.object(forKey: Key.calendarNotice) as? Bool ?? true
        calendarExcluded = defaults.stringArray(forKey: Key.calendarExcluded) ?? []
        pomodoroSound = defaults.object(forKey: Key.pomodoroSound) as? Bool ?? true
        pomodoroDuckMusic = defaults.object(forKey: Key.pomodoroDuckMusic) as? Bool ?? true
        pomodoroDuckLevel = int(Key.pomodoroDuckLevel, Self.duckLevels, 35)
    }
}

/// De qué apps se muestra lo que suena. El "Ahora suena" de macOS es de una sola app a la vez: con "Solo TIDAL",
/// si un vídeo del navegador se lo quita, la franja desaparece hasta que TIDAL lo recupere
enum NowPlayingSource: String, CaseIterable, Identifiable {
    case any, tidal

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Cualquier app"
        case .tidal: "Solo TIDAL"
        }
    }

    func accepts(_ bundleIdentifier: String) -> Bool {
        self == .any || bundleIdentifier == NowPlaying.tidalBundleID
    }
}

extension AppSettings {
    // "Sin atajo" se guarda vacío, para distinguirlo de no haberlo cambiado nunca
    private static func save(_ shortcut: HotKeyShortcut?, forKey key: String, in defaults: UserDefaults) {
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    // Sin valor guardado (o ilegible), el de por defecto; guardado vacío, sin atajo
    private static func shortcut(forKey key: String, in defaults: UserDefaults, fallback: HotKeyShortcut) -> HotKeyShortcut? {
        switch defaults.data(forKey: key) {
        case let data? where data.isEmpty: nil
        case let data?: (try? JSONDecoder().decode(HotKeyShortcut.self, from: data)) ?? fallback
        case nil: fallback
        }
    }
}

/// Velocidad de las alas al recogerse y volver a salir cuando cambia el escritorio
enum SwitchSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast, instant

    var id: Self { self }

    var title: String {
        switch self {
        case .slow: "Lenta"
        case .normal: "Normal"
        case .fast: "Rápida"
        case .instant: "Sin animación"
        }
    }

    /// Cuántas veces más rápida que la normal; nil, sin animación
    var factor: Double? {
        switch self {
        case .slow: 0.6
        case .normal: 1
        case .fast: 1.6
        case .instant: nil
        }
    }

    /// nil hace el cambio sin animar
    func animation(_ base: Animation) -> Animation? {
        factor.map { base.speed($0) }
    }

    /// Un tiempo de la animación normal a esta velocidad
    func scaled(_ duration: Duration) -> Duration {
        guard let factor else { return .zero }
        return duration * (1 / factor)
    }
}
