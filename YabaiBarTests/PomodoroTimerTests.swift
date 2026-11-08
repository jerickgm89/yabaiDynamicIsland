import Foundation
import Testing
@testable import YabaiBar

// Tiempos cortos para leer los tests fácil: foco 100 s, descanso corto 20, largo 60, descanso largo cada 2 focos,
// aviso 30 s antes. Los descansos empiezan solos y el foco no
private let rules = PomodoroRules(
    durations: PomodoroDurations(focus: 100, shortBreak: 20, longBreak: 60, roundsUntilLongBreak: 2),
    warning: 30, autoStartBreaks: true, autoStartFocus: false
)
private let start = Date(timeIntervalSince1970: 1_000_000)
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

// #expect no admite llamadas que mutan: estos ayudantes devuelven el temporizador y lo que avisó
private func advanced(_ timer: PomodoroTimer, to seconds: TimeInterval, rules: PomodoroRules = rules) -> (PomodoroTimer, [PomodoroEvent]) {
    var timer = timer
    let events = timer.advance(to: start + seconds, rules: rules, calendar: utc)
    return (timer, events)
}

private func started(rules: PomodoroRules = rules) -> PomodoroTimer {
    var timer = PomodoroTimer()
    timer.start(at: start, rules: rules)
    return timer
}

struct PomodoroTimerTests {
    @Test func startsWithAFocus() {
        let timer = started()
        #expect(timer.phase == .focus)
        #expect(timer.state == .running(endsAt: start + 100))
        #expect(timer.remaining(at: start + 40) == 60)
        #expect(timer.progress(at: start + 25) == 0.25)
    }

    @Test func warnsOnceBeforeTheEnd() {
        let timer = started()
        #expect(timer.nextDeadline(rules: rules) == start + 70)
        let (early, nothing) = advanced(timer, to: 69)
        #expect(nothing.isEmpty)
        #expect(!early.warned)
        let (warned, events) = advanced(timer, to: 70)
        #expect(events == [.warning(.focus)])
        #expect(warned.nextDeadline(rules: rules) == start + 100)
        #expect(advanced(warned, to: 80).1.isEmpty)
    }

    // El descanso empieza solo, a la hora en que acabó el foco
    @Test func aFinishedFocusStartsTheBreak() {
        let (timer, events) = advanced(started(), to: 100.5)
        #expect(events == [.finished(.focus, next: .shortBreak)])
        #expect(timer.phase == .shortBreak)
        #expect(timer.state == .running(endsAt: start + 120))
        #expect(timer.completed(on: start, calendar: utc) == 1)
    }

    // El foco no empieza solo: queda listo
    @Test func aFinishedBreakLeavesTheFocusReady() {
        let (afterFocus, _) = advanced(started(), to: 100)
        let (timer, events) = advanced(afterFocus, to: 120)
        #expect(events == [.finished(.shortBreak, next: .focus)])
        #expect(timer.phase == .focus)
        #expect(timer.state == .ready)
        #expect(timer.remaining(at: start + 200) == 0)
    }

    // Cada 2 focos, el descanso largo; tras él, la ronda vuelve a empezar
    @Test func everySecondFocusGetsTheLongBreak() {
        var timer = started()
        var finished: [PomodoroEvent] = []
        var now: TimeInterval = 0
        for _ in 0..<4 {
            let (next, events) = advanced(timer, to: now + 1000)
            finished += events.filter { if case .finished = $0 { true } else { false } }
            timer = next
            now += 1000
            if timer.state == .ready { timer.start(at: start + now, rules: rules) }
        }
        let nexts: [PomodoroPhase] = finished.compactMap { if case let .finished(_, next) = $0 { next } else { nil } }
        #expect(nexts == [.shortBreak, .focus, .longBreak, .focus])
        #expect(timer.completedInRound == 0)
    }

    @Test func pausingKeepsTheRemainingTime() {
        var timer = started()
        timer.pause(at: start + 40)
        #expect(timer.state == .paused(remaining: 60))
        #expect(timer.nextDeadline(rules: rules) == nil)
        #expect(advanced(timer, to: 500).1.isEmpty)
        timer.resume(at: start + 500)
        #expect(timer.state == .running(endsAt: start + 560))
    }

    // Saltar un foco no lo cuenta, y el descanso empieza ya
    @Test func skippingDoesNotCount() {
        var timer = started()
        timer.skip(at: start + 10, rules: rules)
        #expect(timer.phase == .shortBreak)
        #expect(timer.state == .running(endsAt: start + 30))
        #expect(timer.completed(on: start, calendar: utc) == 0)
        #expect(timer.completedInRound == 0)
    }

    @Test func stoppingKeepsTodaysCount() {
        var (timer, _) = advanced(started(), to: 100)
        timer.stop()
        #expect(!timer.isActive)
        #expect(timer.phase == .focus)
        #expect(timer.completed(on: start, calendar: utc) == 1)
    }

    // Tras dormir una hora: un solo final de fase, sin aviso, y el descanso empieza al despertar
    @Test func wakingUpLateDoesNotReplayPhases() {
        let (timer, events) = advanced(started(), to: 3600)
        #expect(events == [.finished(.focus, next: .shortBreak)])
        #expect(timer.state == .running(endsAt: start + 3620))
    }

    @Test func todaysCountResetsAtMidnight() {
        let (timer, _) = advanced(started(), to: 100)
        #expect(timer.completed(on: start, calendar: utc) == 1)
        #expect(timer.completed(on: start + 86_400, calendar: utc) == 0)
    }

    @Test func noWarningWhenItIsOffOrLongerThanThePhase() {
        var quiet = rules
        quiet.warning = nil
        #expect(started(rules: quiet).nextDeadline(rules: quiet) == start + 100)
        var tooLong = rules
        tooLong.warning = 200
        #expect(started(rules: tooLong).nextDeadline(rules: tooLong) == start + 100)
    }

    // Se guarda en UserDefaults: tiene que volver igual
    @Test func survivesEncoding() throws {
        var timer = started()
        timer.pause(at: start + 40)
        let data = try JSONEncoder().encode(timer)
        #expect(try JSONDecoder().decode(PomodoroTimer.self, from: data) == timer)
    }
}

struct PomodoroPresetTests {
    @Test func recognisesEachPreset() {
        #expect(PomodoroPreset.matching(focus: 25, shortBreak: 5, longBreak: 15, rounds: 4) == .classic)
        #expect(PomodoroPreset.matching(focus: 50, shortBreak: 10, longBreak: 30, rounds: 2) == .long)
        #expect(PomodoroPreset.matching(focus: 15, shortBreak: 3, longBreak: 10, rounds: 4) == .short)
        #expect(PomodoroPreset.matching(focus: 30, shortBreak: 5, longBreak: 15, rounds: 4) == .custom)
    }
}

// Cuatro espacios: cuerpo de 580 pt en una isla de 618. La música y el Pomodoro comparten la fila (y = 126–222): la
// música se lleva 300 pt (33–333), porque el Pomodoro no baja de 220, y el Pomodoro empieza en x = 365, tras la
// línea. Los botones van debajo del texto (y = 184–214): los de la música en 127–229 y los del Pomodoro en 459–561
struct PomodoroLayoutTests {
    private func layout(pomodoro: Bool = true) -> IslandExpandedLayout {
        let spaces = (1...4).map { SpaceSummary(index: $0, isFocused: $0 == 1, apps: []) }
        return IslandExpandedLayout(
            spaces: spaces, minBodyWidth: 400, maxBodyWidth: 2000, topHeight: 38, hasMedia: true,
            hasKeepAwake: true, hasPomodoro: pomodoro, hasPomodoroButton: true
        )
    }

    private func control(_ x: CGFloat, _ y: CGFloat, pomodoro: Bool = true) -> IslandExpandedLayout.Control? {
        layout(pomodoro: pomodoro).control(at: CGPoint(x: x, y: y), islandWidth: 618, topHeight: 38)
    }

    // Con los dos, la isla mide lo mismo que solo con la música: comparten la fila
    @Test func sharingTheRowKeepsTheIslandHeight() {
        #expect(layout(pomodoro: false).height == 236)
        #expect(layout().height == 236)
        #expect(layout().musicSection == CGRect(x: 0, y: 0, width: 300, height: 96))
        #expect(layout().pomodoroSection == CGRect(x: 332, y: 0, width: 220, height: 96))
        #expect(layout().dividerX == 316)
    }

    @Test func findsTheControlsOfBothParts() {
        #expect(control(60, 150) == .artwork)
        #expect(control(142, 195) == .previous)
        #expect(control(214, 195) == .next)
        #expect(control(476, 195) == .pomodoroPlayPause)
        #expect(control(512, 195) == .pomodoroSkip)
        #expect(control(548, 195) == .pomodoroStop)
        #expect(control(410, 150) == nil)
        // Sin Pomodoro, los botones de la música vuelven a la derecha
        #expect(control(570, 174, pomodoro: false) == .next)
    }

    // El gesto de dos dedos de lado solo cuenta sobre la música, no sobre el Pomodoro
    @Test func theSwipeOnlyCountsOverTheMusic() {
        #expect(layout().musicContains(CGPoint(x: 200, y: 150), islandWidth: 618, topHeight: 38))
        #expect(!layout().musicContains(CGPoint(x: 480, y: 150), islandWidth: 618, topHeight: 38))
    }

    // Con pocos escritorios, la isla se ensancha para que quepan las dos partes con sus botones
    @Test func fewDesktopsStillFitBothParts() throws {
        let spaces = [SpaceSummary(index: 1, isFocused: true, apps: [])]
        let narrow = IslandExpandedLayout(
            spaces: spaces, minBodyWidth: 364, maxBodyWidth: 2000, topHeight: 38, hasMedia: true, hasPomodoro: true
        )
        let minimum: CGFloat = 2 * 14 + 2 * 220 + 2 * 16
        #expect(narrow.bodyWidth == minimum)
        let pomodoro = try #require(narrow.pomodoroSection)
        for item in narrow.controlFrames(IslandExpandedLayout.pomodoroControls, in: pomodoro) {
            #expect(item.frame.maxX <= pomodoro.maxX)
        }
    }

    // Arriba a la izquierda, x = 19 + 14 = 33, y la taza justo a su derecha (33 + 26 + 4)
    @Test func theButtonSitsInTheTopLeftCorner() {
        #expect(layout().pomodoroButtonFrame(islandWidth: 618, topHeight: 38) == CGRect(x: 33, y: 6, width: 26, height: 26))
        #expect(layout().keepAwakeFrame(islandWidth: 618, topHeight: 38) == CGRect(x: 63, y: 6, width: 26, height: 26))
        #expect(control(46, 19) == .pomodoroToggle)
        #expect(control(76, 19) == .keepAwake)
    }
}

struct PomodoroPeekTests {
    @Test func aStartedBreakSaysHowLongItLasts() {
        let (timer, events) = advanced(started(), to: 100)
        let peek = PomodoroPeek.make(for: events[0], timer: timer, rules: rules)
        #expect(peek == PomodoroPeek(phase: .shortBreak, kind: .started(minutes: 1)))
        #expect(peek.title == "Descanso")
        #expect(peek.subtitle == "1 min")
    }

    // El foco no empieza solo: el aviso dice que espera
    @Test func aReadyFocusWaitsForYou() {
        let (afterFocus, _) = advanced(started(), to: 100)
        let (timer, events) = advanced(afterFocus, to: 120)
        let peek = PomodoroPeek.make(for: events[0], timer: timer, rules: rules)
        #expect(peek == PomodoroPeek(phase: .focus, kind: .ready))
        #expect(peek.subtitle == "Listo para empezar")
    }

    @Test func theWarningSaysWhatIsLeft() {
        let (timer, events) = advanced(started(), to: 70)
        let peek = PomodoroPeek.make(for: events[0], timer: timer, rules: rules)
        #expect(peek.title == "Quedan 30 s")
        #expect(peek.subtitle == "del foco")
    }

    // El Pomodoro va antes que la batería, y la batería antes que la canción; solo la canción y el Pomodoro
    // abren las alas
    @Test func peeksHaveAPriority() {
        let pomodoro = IslandPeek.pomodoro(PomodoroPeek(phase: .focus, kind: .ready))
        let battery = IslandPeek.battery(.pluggedIn, level: 80)
        #expect(pomodoro.priority > battery.priority)
        #expect(battery.priority > IslandPeek.track.priority)
        #expect(pomodoro.widensWings && IslandPeek.track.widensWings && !battery.widensWings)
    }

    @Test func theRingGoesLast() {
        let spaces = [SpaceSummary(index: 1, isFocused: true, apps: []), SpaceSummary(index: 2, isFocused: false, apps: [])]
        let layout = IslandLayout(spaces: spaces, statusItems: [.pomodoro, .music, .keepAwake])
        #expect(layout.statusItems == [.music, .keepAwake, .pomodoro])
    }
}

// Lo que enseña la isla tras pulsar el atajo del Pomodoro
struct PomodoroStatusTests {
    @Test func afterStartingItSaysHowLongTheFocusIs() {
        #expect(PomodoroPeek.status(of: started(), at: start) == PomodoroPeek(phase: .focus, kind: .started(minutes: 2)))
    }

    @Test func afterPausingAndResumingItSaysWhatIsLeft() {
        var timer = started()
        timer.pause(at: start + 40)
        let paused = PomodoroPeek.status(of: timer, at: start + 40)
        #expect(paused == PomodoroPeek(phase: .focus, kind: .paused))
        #expect(paused?.subtitle == "En pausa")
        timer.resume(at: start + 50)
        let resumed = PomodoroPeek.status(of: timer, at: start + 50)
        #expect(resumed == PomodoroPeek(phase: .focus, kind: .resumed(minutes: 1)))
        #expect(resumed?.subtitle == "Quedan 1 min")
    }

    @Test func nothingWithoutASession() {
        #expect(PomodoroPeek.status(of: PomodoroTimer(), at: start) == nil)
    }
}
