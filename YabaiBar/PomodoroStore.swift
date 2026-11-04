import AppKit
import Observation
import os

// El Pomodoro publicado para la isla. Espera con una sola tarea al siguiente aviso o final de fase (nunca cuenta
// cada segundo), lo guarda en UserDefaults para seguir tras reiniciar la app y vuelve a mirar al despertar el Mac.
@MainActor
@Observable
final class PomodoroStore {
    private(set) var timer: PomodoroTimer
    /// Lo último que pasó, para los avisos de la isla y el sonido
    var onEvent: (@MainActor (PomodoroEvent) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Solo en DEBUG: tiempos en segundos para probar sin esperar 25 minutos
    @ObservationIgnored private var demoDurations: PomodoroDurations?

    private static let key = "pomodoro"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        timer = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PomodoroTimer.self, from: $0) }
            ?? PomodoroTimer()
        // Lo que pasó con la app cerrada no avisa: solo se pone al día
        _ = timer.advance(to: .now, rules: rules)
        save()
        schedule()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var rules: PomodoroRules {
        PomodoroRules(
            durations: demoDurations ?? settings.pomodoroDurations,
            warning: settings.pomodoroWarning > 0 ? TimeInterval(settings.pomodoroWarning) : nil,
            autoStartBreaks: settings.pomodoroAutoStartBreaks,
            autoStartFocus: settings.pomodoroAutoStartFocus
        )
    }

    // MARK: - Lo que hace el usuario

    /// El botón principal: empieza, pausa o reanuda según el estado
    func toggle() {
        switch timer.state {
        case .stopped, .ready: change { $0.start(at: .now, rules: rules) }
        case .running: change { $0.pause(at: .now) }
        case .paused: change { $0.resume(at: .now) }
        }
    }

    func skip() {
        change { $0.skip(at: .now, rules: rules) }
    }

    func stop() {
        demoDurations = nil
        change { $0.stop() }
    }

    #if DEBUG
    /// Una sesión con tiempos en segundos (foco 45, descanso 35, largo 40, el largo cada 2) para probar los avisos
    func startDemo() {
        demoDurations = PomodoroDurations(focus: 45, shortBreak: 35, longBreak: 40, roundsUntilLongBreak: 2)
        change {
            $0.stop()
            $0.start(at: .now, rules: rules)
        }
    }
    #endif

    // MARK: - El paso del tiempo

    private func change(_ update: (inout PomodoroTimer) -> Void) {
        let before = timer.state
        update(&timer)
        Logger.app.info("Pomodoro: \(Self.describe(self.timer), privacy: .public)")
        if !timer.isActive, before != .stopped { demoDurations = nil }
        save()
        schedule()
    }

    // Una sola tarea, hasta el siguiente aviso o final. Task.sleep usa el reloj continuo, que sigue contando con
    // el Mac dormido: al despertar, si ya pasó, salta enseguida. Sin tolerancia explícita, macOS agrupa los
    // temporizadores y los retrasaba hasta 2 s en una espera de 30 s
    private func schedule() {
        deadlineTask?.cancel()
        guard let deadline = timer.nextDeadline(rules: rules) else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)), tolerance: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func tick() {
        let events = timer.advance(to: .now, rules: rules)
        for event in events {
            Logger.app.info("Pomodoro: \(Self.describe(event), privacy: .public)")
            onEvent?(event)
        }
        if !events.isEmpty { save() }
        schedule()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(timer), forKey: Self.key)
    }

    private static func describe(_ event: PomodoroEvent) -> String {
        switch event {
        case .warning(let phase): "aviso antes del final de \(phase.rawValue)"
        case .finished(let phase, let next): "fin de \(phase.rawValue), sigue \(next.rawValue)"
        }
    }

    private static func describe(_ timer: PomodoroTimer) -> String {
        switch timer.state {
        case .stopped: "parado"
        case .ready: "\(timer.phase.rawValue) lista"
        case .running: "\(timer.phase.rawValue) en marcha"
        case .paused: "\(timer.phase.rawValue) en pausa"
        }
    }
}
