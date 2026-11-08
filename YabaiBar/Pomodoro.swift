import Foundation

enum PomodoroPhase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    var isBreak: Bool { self != .focus }

    var title: String {
        switch self {
        case .focus: "Foco"
        case .shortBreak: "Descanso"
        case .longBreak: "Descanso largo"
        }
    }
}

/// Lo que dura cada fase y cada cuántos focos toca el descanso largo
struct PomodoroDurations: Equatable, Sendable {
    var focus: TimeInterval
    var shortBreak: TimeInterval
    var longBreak: TimeInterval
    var roundsUntilLongBreak: Int

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

/// Cómo se encadenan las fases: los avisos, y si los descansos y el foco empiezan solos
struct PomodoroRules: Equatable, Sendable {
    var durations: PomodoroDurations
    /// Segundos antes del final para el aviso; nil, sin aviso
    var warning: TimeInterval?
    var autoStartBreaks: Bool
    var autoStartFocus: Bool
}

enum PomodoroPreset: String, CaseIterable, Identifiable {
    case classic, long, short, custom

    var id: Self { self }

    /// El nombre corto, para las tarjetas de los ajustes
    var name: String {
        switch self {
        case .classic: "Clásico"
        case .long: "Largo"
        case .short: "Corto"
        case .custom: "Personalizado"
        }
    }

    /// En minutos: foco, descanso corto, descanso largo y cada cuántos focos el largo. nil en "Personalizado"
    var minutes: (focus: Int, shortBreak: Int, longBreak: Int, rounds: Int)? {
        switch self {
        case .classic: (25, 5, 15, 4)
        case .long: (50, 10, 30, 2)
        case .short: (15, 3, 10, 4)
        case .custom: nil
        }
    }

    /// El preset que tiene justo estos tiempos, o "Personalizado"
    static func matching(focus: Int, shortBreak: Int, longBreak: Int, rounds: Int) -> PomodoroPreset {
        allCases.first { preset in
            guard let minutes = preset.minutes else { return false }
            return minutes == (focus, shortBreak, longBreak, rounds)
        } ?? .custom
    }
}

/// El aviso del Pomodoro en la isla cerrada: la fase que empieza (o que espera a que la empieces) o lo que queda
struct PomodoroPeek: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case started(minutes: Int)
        case ready
        case warning(seconds: Int)
        /// Con el atajo, al pausar y al reanudar
        case paused
        case resumed(minutes: Int)
    }

    var phase: PomodoroPhase
    var kind: Kind

    var title: String {
        if case .warning(let seconds) = kind { return "Quedan \(seconds) s" }
        return phase.title
    }

    var subtitle: String {
        switch kind {
        case .started(let minutes): "\(minutes) min"
        case .ready: "Listo para empezar"
        case .warning: phase.isBreak ? "del descanso" : "del foco"
        case .paused: "En pausa"
        case .resumed(let minutes): "Quedan \(minutes) min"
        }
    }

    /// Cómo quedó el temporizador tras pulsar el atajo: empezado, reanudado o en pausa. nil sin sesión
    static func status(of timer: PomodoroTimer, at now: Date) -> PomodoroPeek? {
        switch timer.state {
        case .stopped, .ready:
            return nil
        case .paused:
            return PomodoroPeek(phase: timer.phase, kind: .paused)
        case .running:
            let remaining = timer.remaining(at: now)
            // Recién empezada (con un segundo de margen), o a medias
            if remaining >= timer.phaseDuration - 1 {
                return PomodoroPeek(phase: timer.phase, kind: .started(minutes: max(1, Int((timer.phaseDuration / 60).rounded()))))
            }
            return PomodoroPeek(phase: timer.phase, kind: .resumed(minutes: max(1, Int((remaining / 60).rounded(.up)))))
        }
    }

    /// El aviso de un evento del temporizador, con el temporizador ya avanzado
    static func make(for event: PomodoroEvent, timer: PomodoroTimer, rules: PomodoroRules) -> PomodoroPeek {
        switch event {
        case .warning(let phase):
            return PomodoroPeek(phase: phase, kind: .warning(seconds: Int(rules.warning ?? 0)))
        case .finished(_, let next):
            guard timer.isRunning else { return PomodoroPeek(phase: next, kind: .ready) }
            let minutes = max(1, Int((rules.durations.duration(of: next) / 60).rounded()))
            return PomodoroPeek(phase: next, kind: .started(minutes: minutes))
        }
    }
}

enum PomodoroEvent: Equatable, Sendable {
    /// Quedan `warning` segundos de la fase
    case warning(PomodoroPhase)
    /// La fase terminó; `next` es la que sigue, en marcha o lista para empezar
    case finished(PomodoroPhase, next: PomodoroPhase)
}

// Lógica pura del Pomodoro: foco y descansos, con un descanso largo cada N focos. Guarda la hora a la que termina
// la fase y no una cuenta atrás, así que sobrevive al reposo del Mac y a reiniciar la app. Las fechas se pasan
// siempre desde fuera, para poder probarlo.
struct PomodoroTimer: Equatable, Codable, Sendable {
    enum State: Equatable, Codable, Sendable {
        /// Sin Pomodoro
        case stopped
        /// Hay sesión, pero `phase` espera a que la empieces
        case ready
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    /// Si al despertar o al abrir la app la fase terminó hace más que esto, la siguiente empieza ahora y no a la
    /// hora en que tocaba: si no, tras dormir dos horas se encadenarían fases que nadie vio
    static let lateness: TimeInterval = 5

    private(set) var phase = PomodoroPhase.focus
    private(set) var state = State.stopped
    /// Focos terminados en la ronda actual, para el descanso largo
    private(set) var completedInRound = 0
    /// Focos terminados en `day`
    private(set) var completedToday = 0
    private(set) var day: Date?
    /// Ya avisó de que la fase en marcha está por terminar
    private(set) var warned = false
    /// Lo que dura la fase en marcha o en pausa, para el progreso
    private(set) var phaseDuration: TimeInterval = 0

    var isActive: Bool { state != .stopped }
    var isRunning: Bool { if case .running = state { true } else { false } }

    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .stopped, .ready: 0
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): remaining
        }
    }

    /// De 0 a 1, lo que va de la fase
    func progress(at now: Date) -> Double {
        guard phaseDuration > 0, state != .ready, state != .stopped else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / phaseDuration))
    }

    /// Los focos terminados hoy: si `day` es de otro día, ninguno
    func completed(on date: Date, calendar: Calendar = .current) -> Int {
        guard let day, calendar.isDate(day, inSameDayAs: date) else { return 0 }
        return completedToday
    }

    // MARK: - Lo que hace el usuario

    /// Sin sesión, empieza un foco; con la fase lista, la empieza
    mutating func start(at now: Date, rules: PomodoroRules) {
        switch state {
        case .stopped:
            phase = .focus
            completedInRound = 0
            begin(phase: .focus, at: now, rules: rules)
        case .ready:
            begin(phase: phase, at: now, rules: rules)
        case .running, .paused:
            break
        }
    }

    mutating func pause(at now: Date) {
        guard case .running(let endsAt) = state else { return }
        state = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    mutating func resume(at now: Date) {
        guard case .paused(let remaining) = state else { return }
        state = .running(endsAt: now.addingTimeInterval(remaining))
    }

    /// Pasa a la siguiente fase y la empieza ya. Un foco saltado no cuenta como hecho
    mutating func skip(at now: Date, rules: PomodoroRules) {
        guard isActive else { return }
        let next = nextPhase(after: phase, countingFocus: false, rules: rules)
        if phase == .longBreak { completedInRound = 0 }
        begin(phase: next, at: now, rules: rules)
    }

    /// Termina la sesión. Los focos de hoy se conservan
    mutating func stop() {
        state = .stopped
        phase = .focus
        completedInRound = 0
        warned = false
        phaseDuration = 0
    }

    // MARK: - El paso del tiempo

    /// Cuándo hay que volver a mirar: el aviso, si falta, o el final de la fase. nil si no hay nada en marcha
    func nextDeadline(rules: PomodoroRules) -> Date? {
        guard case .running(let endsAt) = state else { return nil }
        if !warned, let warning = rules.warning, warning < phaseDuration {
            return endsAt.addingTimeInterval(-warning)
        }
        return endsAt
    }

    /// Lo que ha pasado hasta `now`: como mucho un aviso y un final de fase. Si la fase terminó, deja la siguiente
    /// en marcha (si empieza sola) o lista
    mutating func advance(to now: Date, rules: PomodoroRules, calendar: Calendar = .current) -> [PomodoroEvent] {
        guard case .running(let endsAt) = state else { return [] }
        var events: [PomodoroEvent] = []
        if now < endsAt {
            if !warned, let warning = rules.warning, warning < phaseDuration, now >= endsAt.addingTimeInterval(-warning) {
                warned = true
                events.append(.warning(phase))
            }
            return events
        }

        let finished = phase
        if finished == .focus {
            if day.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true {
                day = calendar.startOfDay(for: now)
                completedToday = 0
            }
            completedToday += 1
        }
        let next = nextPhase(after: finished, countingFocus: true, rules: rules)
        if finished == .longBreak { completedInRound = 0 }
        events.append(.finished(finished, next: next))

        let startsAlone = next.isBreak ? rules.autoStartBreaks : rules.autoStartFocus
        if startsAlone {
            // A su hora, para no ir perdiendo segundos; si se llega tarde (reposo), desde ahora
            let start = now.timeIntervalSince(endsAt) > Self.lateness ? now : endsAt
            begin(phase: next, at: start, rules: rules)
        } else {
            phase = next
            state = .ready
            warned = false
            phaseDuration = rules.durations.duration(of: next)
        }
        return events
    }

    // MARK: - Privado

    private mutating func begin(phase: PomodoroPhase, at date: Date, rules: PomodoroRules) {
        self.phase = phase
        phaseDuration = rules.durations.duration(of: phase)
        state = .running(endsAt: date.addingTimeInterval(phaseDuration))
        warned = false
    }

    // Tras un foco: el descanso largo si se completa la ronda, si no el corto. Tras cualquier descanso: foco
    private mutating func nextPhase(after phase: PomodoroPhase, countingFocus: Bool, rules: PomodoroRules) -> PomodoroPhase {
        guard phase == .focus else { return .focus }
        if countingFocus { completedInRound += 1 }
        return completedInRound >= rules.durations.roundsUntilLongBreak ? .longBreak : .shortBreak
    }
}
