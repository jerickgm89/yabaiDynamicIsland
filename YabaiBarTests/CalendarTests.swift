import CoreGraphics
import Foundation
import Testing
@testable import YabaiBar

// El calendario de la pestaña Utilidades (fase 42). Las fechas son las del viernes 13 de noviembre de 2026 a las 14:00 UTC, con el
// calendario en UTC y en español, para que no dependan de la máquina

enum CalendarTestSupport {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "es")
        return calendar
    }()

    static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Viernes 13 de noviembre de 2026, 14:00
    static var now: Date { date(13, 14) }

    static func event(
        _ title: String, from start: Date, minutes: Int = 60, allDay: Bool = false, calendarID: String = "a", join: URL? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: "\(title)@\(Int(start.timeIntervalSince1970))", title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
            isAllDay: allDay, calendarID: calendarID, color: .fallback, joinURL: join
        )
    }
}

struct MeetingLinkTests {
    @Test(arguments: [
        "https://meet.google.com/abc-defg-hij", "Únete: https://meet.google.com/abc-defg-hij?authuser=0 gracias",
        "https://meet.google.com/lookup/abcd1234", "https://zoom.us/j/123456789?pwd=abc", "https://us02web.zoom.us/j/123456789",
        "https://company.zoom.us/my/ana", "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x",
        "https://teams.live.com/meet/9876543210", "https://usgovzoom.zoomgov.com/j/1612345678", "https://zoom.us:443/j/123456789",
    ])
    func findsTheMeetingLink(text: String) throws {
        let url = try #require(MeetingLink.find(in: ["", text]))
        #expect(MeetingLink.isMeeting(url), "\(text)")
    }

    // Solo esos servidores, con https y sin usuario en la dirección: lo escribe quien te invita
    @Test(arguments: [
        "http://meet.google.com/abc-defg-hij", "https://meet.google.com/", "https://meet.google.com/landing", "https://evil.example/zoom.us/j/123",
        "https://zoom.us.evil.example/j/123", "https://notzoom.us/j/123", "https://meet.google.com@evil.example/abc-defg-hij",
        "https://user:pass@zoom.us/j/123", "https://zoom.us/pricing", "https://teams.microsoft.com/", "ftp://zoom.us/j/1",
        "https://teams.microsoft.com.evil.example/l/meetup-join/x", "https://webex.com/meet/ana", "no hay enlace aquí",
        // Un navegador resuelve los `..` y acabaría en otra página del mismo servidor
        "https://meet.google.com/lookup/../linkredirect?dest=https://evil.example", "https://zoom.us/j/../cualquier-pagina",
        "https://zoom.us/j/%2e%2e/x", "https://zoom.us/j/%2E%2E/x", "https://zoom.us/j/..%2fx", "https://zoom.us//j/123",
        "https://zoom.us/j/123%5cevil", "https://meet.google.com/abc-defg-hij/extra", "https://meet.google.com/abc-defg-hijk",
        "https://zoom.us:8443/j/123456789", "https://teams.microsoft.com/l/meetup-join/../../x",
    ])
    func rejectsAnythingElse(text: String) {
        #expect(MeetingLink.find(in: [text]) == nil, "\(text)")
    }

    @Test func theFirstMeetingLinkWinsAndOtherLinksAreSkipped() throws {
        let texts = ["https://example.com/agenda", "ver https://example.com y https://zoom.us/j/111 o https://meet.google.com/abc-defg-hij"]
        #expect(try #require(MeetingLink.find(in: texts)).absoluteString == "https://zoom.us/j/111")
        #expect(MeetingLink.find(in: []) == nil)
        #expect(MeetingLink.find(in: [String(repeating: "https://zoom.us/j/1", count: 80)]) == nil)
    }
}

struct CalendarStripTests {
    private let calendar = CalendarTestSupport.calendar
    private let now = CalendarTestSupport.now

    private func days(offset: Int = 0, selected: Date? = nil, events: [CalendarEvent] = []) -> [CalendarDay] {
        let center = CalendarStrip.center(weekOffset: offset, now: now, calendar: calendar)
        return CalendarStrip.days(center: center, selected: selected ?? center, events: events, now: now, calendar: calendar)
    }

    @Test func sevenDaysCenteredOnToday() {
        let days = days()
        #expect(days.map(\.number) == [10, 11, 12, 13, 14, 15, 16])
        #expect(days[3].isToday && days.filter(\.isToday).count == 1)
        #expect(days[3].date == CalendarTestSupport.date(13))
    }

    // La inicial sobre el número, y hoy con su nombre corto, en mayúsculas y sin punto
    @Test func labelsAreTheInitialAndTodayHasItsName() {
        #expect(days().map(\.label) == ["M", "X", "J", "VIE", "S", "D", "L"])
    }

    @Test func weekendsAreMarked() {
        #expect(days().map(\.isWeekend) == [false, false, false, false, true, true, false])
    }

    @Test func theSelectedDayIsMarkedAndTodayIsTheDefault() {
        #expect(days().map(\.isSelected) == [false, false, false, true, false, false, false])
        #expect(days(selected: CalendarTestSupport.date(15)).map(\.isSelected) == [false, false, false, false, false, true, false])
    }

    @Test func aDotMarksTheDaysWithEvents() {
        let events = [
            CalendarTestSupport.event("Hoy", from: CalendarTestSupport.date(13, 9)),
            CalendarTestSupport.event("Sábado", from: CalendarTestSupport.date(14, 20), minutes: 30),
            // Todo el día: el 12 y acaba a medianoche, sin tocar el 13
            CalendarTestSupport.event("Ayer", from: CalendarTestSupport.date(12), minutes: 24 * 60, allDay: true),
            // Fuera de la tira
            CalendarTestSupport.event("Lejos", from: CalendarTestSupport.date(20, 9)),
        ]
        #expect(days(events: events).map(\.hasEvents) == [false, false, true, true, true, false, false])
    }

    // Un evento que cruza la medianoche toca los dos días
    @Test func anEventAcrossMidnightTouchesBothDays() {
        let night = CalendarTestSupport.event("Guardia", from: CalendarTestSupport.date(13, 23), minutes: 120)
        #expect(days(events: [night]).map(\.hasEvents) == [false, false, false, true, true, false, false])
    }

    @Test func swipingMovesTheStripByWeeks() {
        let next = days(offset: 1)
        #expect(next.map(\.number) == [17, 18, 19, 20, 21, 22, 23])
        let anyToday = next.contains { $0.isToday }
        #expect(!anyToday)
        // Hacia atrás también: hoy queda a 7 días, fuera de la tira
        #expect(days(offset: -1).map(\.number) == [3, 4, 5, 6, 7, 8, 9])
        #expect(days(offset: 1).first { $0.isSelected }?.number == 20)
    }

    @Test func theMonthTitleHasTheYearOnlyWhenItIsNotThisOne() {
        func title(offset: Int) -> String {
            CalendarStrip.monthTitle(center: CalendarStrip.center(weekOffset: offset, now: now, calendar: calendar), now: now, calendar: calendar)
        }
        #expect(title(offset: 0) == "NOVIEMBRE")
        #expect(title(offset: 4) == "DICIEMBRE")
        #expect(title(offset: 8) == "ENERO 2027")
    }
}

struct CalendarAgendaTests {
    private let calendar = CalendarTestSupport.calendar
    private let now = CalendarTestSupport.now

    private func items(_ events: [CalendarEvent], day: Int = 13) -> [CalendarAgendaItem] {
        CalendarAgenda.items(for: CalendarTestSupport.date(day), events: events, now: now, calendar: calendar)
    }

    @Test func todayHidesWhatAlreadyEndedAndMarksWhatIsGoingOn() {
        let events = [
            CalendarTestSupport.event("Desayuno", from: CalendarTestSupport.date(13, 8), minutes: 60),
            CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 13, 30), minutes: 60),
            CalendarTestSupport.event("Café", from: CalendarTestSupport.date(13, 16)),
            CalendarTestSupport.event("Cena", from: CalendarTestSupport.date(13, 21)),
        ]
        let shown = items(events)
        #expect(shown.map(\.event.title) == ["Reunión", "Café"])
        #expect(shown.map(\.isInProgress) == [true, false])
        #expect(shown.map(\.timeText) == ["13:30", "16:00"])
    }

    @Test func anEventThatEndsExactlyNowIsGone() {
        let ends = CalendarTestSupport.event("Acaba", from: CalendarTestSupport.date(13, 13), minutes: 60)
        #expect(items([ends]).isEmpty)
        let starts = CalendarTestSupport.event("Empieza", from: CalendarTestSupport.date(13, 14), minutes: 60)
        #expect(items([starts]).first?.isInProgress == true)
    }

    @Test func allDayEventsComeFirstAndAreNeverInProgress() {
        let events = [
            CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 15)),
            CalendarTestSupport.event("Cumpleaños", from: CalendarTestSupport.date(13), minutes: 24 * 60, allDay: true),
        ]
        let shown = items(events)
        #expect(shown.map(\.event.title) == ["Cumpleaños", "Reunión"])
        #expect(shown.map(\.timeText) == ["Todo el día", "15:00"])
        #expect(shown.map(\.isInProgress) == [false, false])
    }

    @Test func onlyTwoFit() {
        let events = (0..<5).map { CalendarTestSupport.event("E\($0)", from: CalendarTestSupport.date(13, 15 + $0)) }
        #expect(items(events).map(\.event.title) == ["E0", "E1"])
    }

    // Otro día enseña todos sus eventos, también los que ya pasaron en el reloj
    @Test func anotherDayShowsItsWholeAgenda() {
        let events = [
            CalendarTestSupport.event("Tarde", from: CalendarTestSupport.date(14, 18)),
            CalendarTestSupport.event("Mañana", from: CalendarTestSupport.date(14, 8)),
            CalendarTestSupport.event("Hoy", from: CalendarTestSupport.date(13, 18)),
        ]
        #expect(items(events, day: 14).map(\.event.title) == ["Mañana", "Tarde"])
        let past = CalendarTestSupport.event("Antes", from: CalendarTestSupport.date(12, 8))
        #expect(items([past], day: 12).map(\.event.title) == ["Antes"])
        #expect(items([past], day: 12).first?.isInProgress == false)
    }

    // Un evento con hora que empezó otro día no enseña la hora de aquel día
    @Test func aMultiDayEventSaysItContinues() {
        let congress = CalendarTestSupport.event("Congreso", from: CalendarTestSupport.date(12, 9), minutes: 3 * 24 * 60)
        #expect(items([congress], day: 12).first?.timeText == "09:00")
        #expect(items([congress], day: 14).first?.timeText == "Sigue")
    }

    // Con reuniones, solo un evento de todo el día: un festivo y un cumpleaños no esconden lo que empieza pronto
    @Test func onlyOneAllDayEventWhenThereAreMeetings() {
        let events = [
            CalendarTestSupport.event("Festivo", from: CalendarTestSupport.date(13), minutes: 24 * 60, allDay: true),
            CalendarTestSupport.event("Cumpleaños", from: CalendarTestSupport.date(13), minutes: 24 * 60, allDay: true),
            CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 15)),
        ]
        #expect(items(events).map(\.event.title) == ["Cumpleaños", "Reunión"])
        // Sin reuniones, los de todo el día se reparten los dos huecos
        #expect(items(Array(events.prefix(2))).map(\.event.title) == ["Cumpleaños", "Festivo"])
    }

    @Test func theClockIsTwentyFourHours() {
        #expect(CalendarAgenda.clock(CalendarTestSupport.date(13, 9, 5), calendar: calendar) == "09:05")
        #expect(CalendarAgenda.clock(CalendarTestSupport.date(13, 23, 59), calendar: calendar) == "23:59")
        #expect(CalendarAgenda.clock(CalendarTestSupport.date(13, 0, 0), calendar: calendar) == "00:00")
    }
}

struct CalendarSnapshotTests {
    private let calendar = CalendarTestSupport.calendar
    private let now = CalendarTestSupport.now

    private func snapshot(
        _ access: CalendarAccess = .granted, events: [CalendarEvent] = [], selected: Date? = nil, offset: Int = 0
    ) -> CalendarSnapshot {
        CalendarSnapshot.make(access: access, events: events, selected: selected, weekOffset: offset, now: now, calendar: calendar)
    }

    @Test func nothingTodayShowsTheNextThingTomorrow() {
        let events = [CalendarTestSupport.event("Demo", from: CalendarTestSupport.date(14, 9)), CalendarTestSupport.event("Pasado", from: CalendarTestSupport.date(13, 8))]
        let shown = snapshot(events: events)
        #expect(shown.items.isEmpty && shown.emptyTitle == "Nada para hoy" && shown.isShowingToday)
        #expect(shown.upNext?.event.title == "Demo" && shown.upNext?.timeText == "09:00")
    }

    @Test func nothingAtAllSaysNothing() {
        let shown = snapshot()
        #expect(shown.emptyTitle == "Nada para hoy" && shown.upNext == nil)
        // Otro día no habla de mañana
        let other = snapshot(selected: CalendarTestSupport.date(15))
        #expect(other.emptyTitle == "Nada ese día" && other.upNext == nil && !other.isShowingToday)
    }

    // Sin permiso las fechas se ven igual, y no hay ni eventos ni «Nada para hoy»
    @Test func withoutAccessTheStripStillShows() {
        let events = [CalendarTestSupport.event("Secreto", from: CalendarTestSupport.date(13, 15))]
        for access in [CalendarAccess.notDetermined, .denied] {
            let shown = snapshot(access, events: events)
            #expect(shown.days.map(\.number) == [10, 11, 12, 13, 14, 15, 16], "\(access)")
            #expect(shown.items.isEmpty && shown.emptyTitle == nil && shown.upNext == nil)
            let anyDot = shown.days.contains { $0.hasEvents }
            #expect(!anyDot)
            #expect(shown.month == "NOVIEMBRE")
        }
    }

    @Test func aSelectedDayShowsItsEventsAndThePageMovesTheStrip() {
        let events = [CalendarTestSupport.event("Sábado", from: CalendarTestSupport.date(14, 10))]
        let saturday = snapshot(events: events, selected: CalendarTestSupport.date(14))
        #expect(saturday.items.map(\.event.title) == ["Sábado"] && !saturday.isShowingToday)
        let next = snapshot(events: events, offset: 1)
        #expect(next.days.first?.number == 17 && next.isShowingToday == false)
        #expect(next.items.isEmpty && next.emptyTitle == "Nada ese día")
    }
}

struct CalendarTimelineTests {
    private let calendar = CalendarTestSupport.calendar
    private let now = CalendarTestSupport.now

    private func event(_ title: String = "E", minutesFromNow: Int, allDay: Bool = false) -> CalendarEvent {
        CalendarTestSupport.event(title, from: now.addingTimeInterval(TimeInterval(minutesFromNow * 60)), allDay: allDay)
    }

    @Test func theBadgeIsOnInTheFifteenMinutesBeforeAnEvent() {
        #expect(!CalendarTimeline.isBadgeOn(events: [event(minutesFromNow: 16)], at: now))
        #expect(CalendarTimeline.isBadgeOn(events: [event(minutesFromNow: 15)], at: now))
        #expect(CalendarTimeline.isBadgeOn(events: [event(minutesFromNow: 1)], at: now))
        // Ya empezó, o es de todo el día: nada
        #expect(!CalendarTimeline.isBadgeOn(events: [event(minutesFromNow: 0)], at: now))
        #expect(!CalendarTimeline.isBadgeOn(events: [event(minutesFromNow: -5)], at: now))
        #expect(!CalendarTimeline.isBadgeOn(events: [event(minutesFromNow: 5, allDay: true)], at: now))
        #expect(!CalendarTimeline.isBadgeOn(events: [], at: now))
    }

    @Test func aNoticeIsDueFromItsTimeAndOnlyOnce() {
        let soon = event("Pronto", minutesFromNow: 5)
        #expect(CalendarTimeline.dueNotices(events: [soon], now: now, notified: []).map(\.title) == ["Pronto"])
        // Ya avisó
        #expect(CalendarTimeline.dueNotices(events: [soon], now: now.addingTimeInterval(60), notified: [soon.id]).isEmpty)
        // Todavía no toca
        #expect(CalendarTimeline.dueNotices(events: [event(minutesFromNow: 6)], now: now, notified: []).isEmpty)
    }

    // Si el Mac durmió, el aviso llega tarde pero llega, mientras el evento no haya empezado
    @Test func aLateWakeStillNotifiesBeforeTheStartButNotAfter() {
        let meeting = event(minutesFromNow: 3)
        #expect(CalendarTimeline.dueNotices(events: [meeting], now: now, notified: []).count == 1)
        #expect(CalendarTimeline.dueNotices(events: [meeting], now: now.addingTimeInterval(4 * 60), notified: []).isEmpty)
    }

    // El identificador lleva el inicio: un evento movido es otro y vuelve a avisar
    @Test func aMovedEventNotifiesAgain() {
        let original = CalendarTestSupport.event("Reunión", from: now.addingTimeInterval(4 * 60))
        let moved = CalendarTestSupport.event("Reunión", from: now.addingTimeInterval(2 * 60))
        #expect(original.id != moved.id)
        #expect(CalendarTimeline.dueNotices(events: [moved], now: now, notified: [original.id]).count == 1)
    }

    @Test func allDayEventsNeverNotify() {
        #expect(CalendarTimeline.dueNotices(events: [event(minutesFromNow: 5, allDay: true)], now: now, notified: []).isEmpty)
    }

    @Test func theNextWakeIsTheNearestOfTheThreeMoments() {
        let events = [event("Lejos", minutesFromNow: 120), event("Medio", minutesFromNow: 40)]
        // 15 min antes del de dentro de 40 min
        #expect(CalendarTimeline.nextWake(events: events, after: now) == now.addingTimeInterval(25 * 60))
        // Con el punto ya encendido, el aviso a los 5 min
        #expect(CalendarTimeline.nextWake(events: [event(minutesFromNow: 12)], after: now) == now.addingTimeInterval(7 * 60))
        // Con el aviso ya dado, el empiece
        #expect(CalendarTimeline.nextWake(events: [event(minutesFromNow: 3)], after: now) == now.addingTimeInterval(3 * 60))
        #expect(CalendarTimeline.nextWake(events: [event(minutesFromNow: -3)], after: now) == nil)
        #expect(CalendarTimeline.nextWake(events: [event(minutesFromNow: 30, allDay: true)], after: now) == nil)
        #expect(CalendarTimeline.nextWake(events: [], after: now) == nil)
    }

    @Test func theNoticeSaysWhenAndAt() {
        let meeting = CalendarTestSupport.event("Revisión", from: CalendarTestSupport.date(13, 14, 5))
        #expect(CalendarTimeline.noticeSubtitle(for: meeting, at: now, calendar: calendar) == "en 5 min · 14:05")
        #expect(CalendarTimeline.noticeSubtitle(for: meeting, at: now.addingTimeInterval(4 * 60 + 20), calendar: calendar) == "en 1 min · 14:05")
        #expect(CalendarTimeline.noticeSubtitle(for: meeting, at: now.addingTimeInterval(6 * 60), calendar: calendar) == "ahora · 14:05")
    }

    // El aviso va entre Git y el Pomodoro, y no tapa una pregunta de Claude
    @Test func theNoticePriorityIsBetweenGitAndThePomodoro() {
        let notice = IslandPeek.notice(IslandNotice(symbol: "calendar", tone: .info, title: "t", subtitle: "s", priority: 30))
        let git = IslandPeek.notice(GitNotice(repo: "r", kind: .unpushed(commits: 1)).notice)
        let pomodoro = IslandPeek.pomodoro(PomodoroPeek(phase: .shortBreak, kind: .started(minutes: 5)))
        #expect(notice.priority > git.priority && notice.priority < pomodoro.priority)
    }
}

struct CalendarLayoutTests {
    private let size = CGSize(width: 310, height: 112)

    private func control(_ x: CGFloat, _ y: CGFloat, access: CalendarAccess = .granted, joinable: [Bool] = [false, false]) -> CalendarControl? {
        CalendarModuleLayout.control(at: CGPoint(x: x, y: y), in: size, access: access, joinable: joinable)
    }

    @Test func eachDayOfTheStripIsAButton() {
        for index in 0..<7 {
            let frame = CalendarModuleLayout.dayFrame(index, in: size)
            #expect(control(frame.midX, frame.midY) == .day(index))
        }
        // La tira ocupa el ancho del módulo menos los márgenes
        #expect(CalendarModuleLayout.dayFrame(0, in: size).minX == 8)
        #expect(CalendarModuleLayout.dayFrame(6, in: size).maxX == 302)
        #expect(control(2, 40) == nil)
    }

    @Test func eventsOpenCalendarAndJoinHasItsOwnButton() {
        let joinable = [true, false]
        let row0 = CalendarModuleLayout.eventFrame(0, in: size)
        let join = CalendarModuleLayout.joinFrame(0, in: size)
        #expect(control(row0.minX + 20, row0.midY, joinable: joinable) == .event(0))
        #expect(control(join.midX, join.midY, joinable: joinable) == .join(0))
        // Sin enlace, esa zona es del evento
        #expect(control(join.midX, join.midY, joinable: [false, false]) == .event(0))
        let row1 = CalendarModuleLayout.eventFrame(1, in: size)
        #expect(control(row1.midX, row1.midY, joinable: joinable) == .event(1))
        // Bajo la última fila no hay nada
        #expect(control(100, 108) == nil)
        // El botón cabe dentro de su fila
        #expect(row0.contains(join))
    }

    @Test func theArrowsChangeTheWeek() {
        let previous = CalendarModuleLayout.previousFrame(in: size)
        let next = CalendarModuleLayout.nextFrame(in: size)
        #expect(control(previous.midX, previous.midY) == .previousWeek)
        #expect(control(next.midX, next.midY) == .nextWeek)
        #expect(!previous.intersects(next))
        // Con un poco de margen para acertarlas
        #expect(control(next.maxX + 2, next.midY) == .nextWeek)
    }

    @Test func withoutAccessOnlyTheStripAndTheAccessButtonRespond() {
        let button = CalendarModuleLayout.accessFrame(in: size)
        #expect(control(button.midX, button.midY, access: .notDetermined) == .access)
        #expect(control(button.midX, button.midY, access: .denied) == .access)
        // Las filas de eventos no existen sin permiso
        let row = CalendarModuleLayout.eventFrame(0, in: size)
        #expect(control(row.minX + 2, row.minY + 2, access: .notDetermined, joinable: [true, true]) == nil)
        #expect(control(CalendarModuleLayout.dayFrame(3, in: size).midX, 40, access: .denied) == .day(3))
        #expect(CalendarModuleLayout.accessFrame(in: size).maxY <= size.height)
    }

    @Test func theModuleFitsItsBox() {
        #expect(CalendarModuleLayout.eventFrame(1, in: size).maxY <= size.height)
        #expect(CalendarModuleLayout.stripFrame(in: size).maxY <= CalendarModuleLayout.eventFrame(0, in: size).minY)
    }

    // Con la isla de verdad: solo en Utilidades, y en coordenadas de la isla
    @Test func theIslandResolvesCalendarClicksOnlyInUtilities() throws {
        func layout(_ tab: IslandTab) -> IslandExpandedLayout {
            IslandExpandedLayout(
                spaces: [SpaceSummary(index: 1, isFocused: true, apps: [])], minBodyWidth: 396, maxBodyWidth: 1958, topHeight: 38, tab: tab,
                tabs: IslandTab.allCases, developerModules: ModuleID.modules(of: .developer), hasMedia: true, hasKeepAwake: true,
                hasPomodoro: true, hasSettingsButton: true
            )
        }
        let utilities = layout(.utilities)
        let frame = try #require(utilities.calendarFrame(islandWidth: 800, topHeight: 38))
        #expect(frame.size == CGSize(width: 310, height: IslandExpandedLayout.moduleHeight))
        // Debajo de la fila de la música y el Pomodoro
        #expect(frame.minY == 38 + IslandExpandedLayout.gapBelowNotch + IslandExpandedLayout.activityHeight + IslandExpandedLayout.activityGap)
        let day3 = CalendarModuleLayout.dayFrame(3, in: frame.size)
        let point = CGPoint(x: frame.minX + day3.midX, y: frame.minY + day3.midY)
        #expect(utilities.calendarControl(at: point, islandWidth: 800, topHeight: 38, access: .granted, joinable: []) == .day(3))
        #expect(utilities.calendarStripContains(point, islandWidth: 800, topHeight: 38))
        // Fuera del módulo, o en otra pestaña, nada
        #expect(utilities.calendarControl(at: CGPoint(x: 5, y: 5), islandWidth: 800, topHeight: 38, access: .granted, joinable: []) == nil)
        for other in [IslandTab.desktops, .developer] {
            #expect(layout(other).calendarFrame(islandWidth: 800, topHeight: 38) == nil)
            #expect(layout(other).calendarControl(at: point, islandWidth: 800, topHeight: 38, access: .granted, joinable: []) == nil)
            #expect(!layout(other).calendarStripContains(point, islandWidth: 800, topHeight: 38))
        }
    }
}

// MARK: - El almacén, con un calendario falso

@MainActor
final class FakeCalendarSource: CalendarSource {
    var access: CalendarAccess
    var grantsOnRequest = true
    var storedEvents: [CalendarEvent] = []
    var calendarList: [CalendarInfo] = []
    private(set) var requests = 0
    private(set) var lastExcluded: Set<String> = []
    private var changeHandler: (@MainActor () -> Void)?

    init(access: CalendarAccess = .granted) {
        self.access = access
    }

    func requestAccess() async -> Bool {
        requests += 1
        if grantsOnRequest { access = .granted } else { access = .denied }
        return grantsOnRequest
    }

    func calendars() -> [CalendarInfo] { access == .granted ? calendarList : [] }

    func events(from start: Date, to end: Date, excluding: Set<String>) -> [CalendarEvent] {
        lastExcluded = excluding
        guard access == .granted else { return [] }
        return storedEvents.filter { $0.start < end && $0.end > start && !excluding.contains($0.calendarID) }
    }

    func onChange(_ handler: @escaping @MainActor () -> Void) { changeHandler = handler }

    func fireChange() { changeHandler?() }
}

@MainActor
struct CalendarStoreTests {
    final class Clock {
        var now = CalendarTestSupport.now
    }

    private func make(
        access: CalendarAccess = .granted, events: [CalendarEvent] = [], clock: Clock = Clock()
    ) -> (store: CalendarStore, source: FakeCalendarSource, settings: AppSettings, clock: Clock) {
        let source = FakeCalendarSource(access: access)
        source.storedEvents = events
        let settings = AppSettings(defaults: UserDefaults(suiteName: "calendar-tests-\(UUID().uuidString)")!)
        let store = CalendarStore(source: source, settings: settings, calendar: CalendarTestSupport.calendar, clock: { clock.now })
        return (store, source, settings, clock)
    }

    @Test func readsTheEventsOfWhatIsShown() {
        let (store, _, _, _) = make(events: [
            CalendarTestSupport.event("Hoy", from: CalendarTestSupport.date(13, 15)),
            CalendarTestSupport.event("Lejísimos", from: CalendarTestSupport.date(13, 15, month: 3)),
        ])
        store.reload()
        #expect(store.access == .granted)
        #expect(store.events.map(\.title) == ["Hoy"])
        #expect(store.snapshot.items.map(\.event.title) == ["Hoy"])
    }

    @Test func withoutAccessThereAreNoEventsAndTheStripStays() {
        let (store, source, _, _) = make(access: .notDetermined, events: [CalendarTestSupport.event("Secreto", from: CalendarTestSupport.date(13, 15))])
        store.reload()
        #expect(store.access == .notDetermined && store.events.isEmpty && !store.isBadgeOn)
        #expect(store.snapshot.days.count == 7 && store.snapshot.items.isEmpty)
        #expect(source.requests == 0)
    }

    @Test func requestingAccessAsksOnlyOnceAndReadsAfterwards() async {
        let (store, source, _, _) = make(access: .notDetermined, events: [CalendarTestSupport.event("Hoy", from: CalendarTestSupport.date(13, 15))])
        store.reload()
        #expect(await store.requestAccess())
        #expect(source.requests == 1 && store.access == .granted && store.events.count == 1)
        // Ya concedido: no vuelve a preguntar
        #expect(await store.requestAccess())
        #expect(source.requests == 1)
        // Denegado: el sistema no vuelve a preguntar, y la app tampoco
        let denied = make(access: .denied)
        denied.store.reload()
        #expect(!(await denied.store.requestAccess()))
        #expect(denied.source.requests == 0 && denied.store.access == .denied)
    }

    @Test func aRefusedRequestLeavesItDenied() async {
        let (store, source, _, _) = make(access: .notDetermined)
        source.grantsOnRequest = false
        store.reload()
        #expect(!(await store.requestAccess()))
        #expect(store.access == .denied)
    }

    @Test func excludedCalendarsAreNotRead() {
        let (store, source, settings, _) = make(events: [
            CalendarTestSupport.event("Trabajo", from: CalendarTestSupport.date(13, 15), calendarID: "trabajo"),
            CalendarTestSupport.event("Casa", from: CalendarTestSupport.date(13, 16), calendarID: "casa"),
        ])
        settings.calendarExcluded = ["casa"]
        store.reload()
        #expect(source.lastExcluded == ["casa"] && store.events.map(\.title) == ["Trabajo"])
    }

    @Test func selectingADayAndPagingWeeks() {
        let (store, _, _, _) = make(events: [CalendarTestSupport.event("Sábado", from: CalendarTestSupport.date(14, 10))])
        store.reload()
        store.select(dayAt: 4)
        #expect(store.selectedDay == CalendarTestSupport.date(14))
        #expect(store.snapshot.items.map(\.event.title) == ["Sábado"])
        // Una posición que no existe no hace nada
        store.select(dayAt: 9)
        #expect(store.selectedDay == CalendarTestSupport.date(14))
        // Pasar de semana vuelve a elegir el del centro y mueve la tira
        store.shiftWeek(1)
        #expect(store.weekOffset == 1 && store.selectedDay == nil)
        #expect(store.snapshot.days.map(\.number) == [17, 18, 19, 20, 21, 22, 23])
        store.shiftWeek(-2)
        #expect(store.snapshot.days.map(\.number) == [3, 4, 5, 6, 7, 8, 9])
    }

    // Al pasar de semana se leen los eventos de esa semana, aunque queden lejos de hoy
    @Test func pagingReadsTheEventsOfThatWeek() {
        let far = CalendarTestSupport.event("Dentro de un mes", from: CalendarTestSupport.date(11, 10, month: 12))
        let (store, _, _, _) = make(events: [far])
        store.reload()
        #expect(store.events.isEmpty)
        store.shiftWeek(4)
        #expect(store.events.map(\.title) == ["Dentro de un mes"])
        #expect(store.snapshot.days.first { $0.hasEvents }?.number == 11)
    }

    @Test func hidingTheTabGoesBackToToday() {
        let (store, _, _, _) = make()
        store.start()
        defer { store.stop() }
        store.setVisible(true)
        store.select(dayAt: 5)
        store.shiftWeek(2)
        store.setVisible(false)
        #expect(store.selectedDay == nil && store.weekOffset == 0)
    }

    // El aviso sale una vez cuando llega su hora, y el punto azul se enciende 15 minutos antes
    @Test func aNoticeComesFiveMinutesBeforeAndOnlyOnce() {
        let meeting = CalendarTestSupport.event("Revisión", from: CalendarTestSupport.date(13, 14, 30))
        let (store, _, _, clock) = make(events: [meeting])
        var notices: [(String, Date)] = []
        store.onNotice = { notices.append(($0.title, $1)) }
        store.reload()
        // 14:00 y 14:10: faltan 30 y 20 min. Ni aviso ni punto todavía
        clock.now = CalendarTestSupport.date(13, 14, 10)
        store.reload()
        #expect(notices.isEmpty && !store.isBadgeOn)
        // 14:16: faltan 14. El punto, sin aviso
        clock.now = CalendarTestSupport.date(13, 14, 16)
        store.reload()
        #expect(notices.isEmpty && store.isBadgeOn)
        // 14:26: pasó la hora del aviso (14:25)
        clock.now = CalendarTestSupport.date(13, 14, 26)
        store.reload()
        #expect(notices.map(\.0) == ["Revisión"] && notices.first?.1 == clock.now)
        #expect(store.isBadgeOn)
        // Otra lectura (EventKit avisa de cada sincronización) no lo repite
        clock.now = CalendarTestSupport.date(13, 14, 27)
        store.reload()
        #expect(notices.count == 1)
        // Al empezar, el punto se apaga
        clock.now = CalendarTestSupport.date(13, 14, 31)
        store.reload()
        #expect(!store.isBadgeOn && notices.count == 1)
    }

    @Test func aNoticeSwitchedOffNeverComes() {
        let meeting = CalendarTestSupport.event("Revisión", from: CalendarTestSupport.date(13, 14, 30))
        let (store, _, settings, clock) = make(events: [meeting])
        settings.calendarNotice = false
        var notices = 0
        store.onNotice = { _, _ in notices += 1 }
        store.reload()
        clock.now = CalendarTestSupport.date(13, 14, 26)
        store.reload()
        #expect(notices == 0)
        // El punto sí: avisa de que algo viene aunque el aviso esté apagado
        #expect(store.isBadgeOn)
    }

    @Test func whatWasAlreadyDueWhenTheAppStartedDoesNotNotify() {
        let meeting = CalendarTestSupport.event("Revisión", from: CalendarTestSupport.date(13, 14, 3))
        let (store, _, _, _) = make(events: [meeting])
        var notices = 0
        store.onNotice = { _, _ in notices += 1 }
        store.reload()
        #expect(notices == 0 && store.isBadgeOn)
    }

    // Ninguna lectura de por medio (abrir la pestaña, una sincronización) hace perder un aviso: antes se perdía si una lectura pasaba
    // entre la hora del aviso y la aparición del evento
    @Test func anIntermediateReadDoesNotLoseANoticeForAMovedEvent() {
        let original = CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 14, 45))
        let (store, source, _, clock) = make(events: [original])
        var titles: [String] = []
        store.onNotice = { event, _ in titles.append(event.title) }
        store.reload()
        clock.now = CalendarTestSupport.date(13, 14, 26)
        store.reload()
        #expect(titles.isEmpty)
        // Se mueve a las 14:30: su aviso (14:25) ya pasó, pero no se avisó
        source.storedEvents = [CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 14, 30))]
        clock.now = CalendarTestSupport.date(13, 14, 27)
        store.reload()
        #expect(titles == ["Reunión"])
    }

    // Con el reloj yendo hacia atrás (un cambio de hora) un aviso ya dado no se repite
    @Test func aClockGoingBackwardsDoesNotRepeatANotice() {
        let meeting = CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 14, 30))
        let (store, _, _, clock) = make(events: [meeting])
        var notices = 0
        store.onNotice = { _, _ in notices += 1 }
        store.reload()
        clock.now = CalendarTestSupport.date(13, 14, 26)
        store.reload()
        clock.now = CalendarTestSupport.date(13, 14, 10)
        store.reload()
        clock.now = CalendarTestSupport.date(13, 14, 27)
        store.reload()
        #expect(notices == 1)
    }

    // Un evento que ya tenía su aviso pasado al abrir la pestaña (lo hace `setVisible`) lo da una vez, no dos
    @Test func openingTheTabBetweenTheTimeAndTheStartNotifiesOnce() {
        let meeting = CalendarTestSupport.event("Reunión", from: CalendarTestSupport.date(13, 14, 30))
        let (store, _, _, clock) = make(events: [meeting])
        store.start()
        defer { store.stop() }
        var notices = 0
        store.onNotice = { _, _ in notices += 1 }
        clock.now = CalendarTestSupport.date(13, 14, 26)
        store.setVisible(true)
        store.reload()
        store.setVisible(false)
        #expect(notices == 1)
    }

    // Parar y volver a empezar deja todo en marcha: antes la lectura con debounce se quedaba bloqueada
    @Test func stoppingAndStartingAgainWorks() async throws {
        let (store, source, _, _) = make(events: [CalendarTestSupport.event("Hoy", from: CalendarTestSupport.date(13, 15))])
        store.start()
        source.fireChange()
        store.stop()
        store.start()
        defer { store.stop() }
        source.storedEvents.append(CalendarTestSupport.event("Nuevo", from: CalendarTestSupport.date(13, 16)))
        source.fireChange()
        let deadline = Date().addingTimeInterval(5)
        while store.events.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.events.map(\.title) == ["Hoy", "Nuevo"])
    }

    // Un evento que se crea con poca antelación avisa en cuanto se lee, y uno movido avisa a su nueva hora
    @Test func aNewEventSoonToStartNotifiesWhenItAppears() {
        let (store, source, _, clock) = make()
        var titles: [String] = []
        store.onNotice = { event, _ in titles.append(event.title) }
        store.reload()
        clock.now = CalendarTestSupport.date(13, 14, 30)
        source.storedEvents = [CalendarTestSupport.event("Improvisada", from: CalendarTestSupport.date(13, 14, 33))]
        source.fireChange()
        store.reload()
        #expect(titles == ["Improvisada"])
    }

    @Test func anAllDayEventNeitherNotifiesNorLightsTheBadge() {
        let allDay = CalendarTestSupport.event("Festivo", from: CalendarTestSupport.date(13), minutes: 24 * 60, allDay: true)
        let (store, _, _, clock) = make(events: [allDay])
        var notices = 0
        store.onNotice = { _, _ in notices += 1 }
        store.reload()
        clock.now = CalendarTestSupport.date(13, 23, 56)
        store.reload()
        #expect(notices == 0 && !store.isBadgeOn)
        #expect(store.snapshot.items.map(\.timeText) == ["Todo el día"])
    }

    // Una sola espera: el punto se apaga solo cuando empieza el evento, sin que nadie pregunte
    @Test func theBadgeGoesOffByItselfWhenTheEventStarts() async throws {
        let source = FakeCalendarSource()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "calendar-tests-\(UUID().uuidString)")!)
        let store = CalendarStore(source: source, settings: settings, calendar: CalendarTestSupport.calendar)
        defer { store.stop() }
        source.storedEvents = [CalendarTestSupport.event("Ya mismo", from: Date().addingTimeInterval(2.5))]
        store.start()
        #expect(store.isBadgeOn)
        let deadline = Date().addingTimeInterval(8)
        while store.isBadgeOn, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!store.isBadgeOn)
    }
}

// MARK: - Lo que sale por la isla

@MainActor
struct CalendarNoticeTests {
    @Test func aCalendarNoticeOpensCalendarFromTheNoticeLog() {
        #expect(NoticeRows.action(for: .calendar) == .activate)
        let rows = NoticeRows.content(
            of: [NoticeEntry(date: CalendarTestSupport.now, tone: .active, title: "Revisión", detail: "en 5 min · 14:05", origin: .calendar)],
            time: { CalendarAgenda.clock($0, calendar: CalendarTestSupport.calendar) }
        ).rows
        #expect(rows.first?.trailing == "14:00" && rows.first?.primaryAction == .activate)
    }

    @Test func theSettingsHaveTheirDefaultsAndAreRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "calendar-settings-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.calendarNotice && settings.calendarExcluded.isEmpty)
        settings.calendarNotice = false
        settings.calendarExcluded = ["a", "b"]
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.calendarNotice && reloaded.calendarExcluded == ["a", "b"])
    }
}
