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

    /// El botón y la franja del Pomodoro en la isla abierta. Al apagarlo se termina la sesión
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
