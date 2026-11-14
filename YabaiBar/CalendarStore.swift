import AppKit
import EventKit
import Foundation
import Observation
import os

// El calendario de la pestaña Utilidades: los eventos de Calendario (iCloud, Google… todas las cuentas que el usuario tenga allí)
// con EventKit, y el aviso 5 min antes de cada evento. Con permiso de lectura de los eventos (`requestFullAccessToEvents`); sin él,
// el módulo enseña la tira de días, porque las fechas no lo necesitan, y un botón «Dar acceso».
//
// Funciona con la isla cerrada, pero sin consultar nada cada poco: una sola espera hasta la próxima hora que importa (el punto azul
// a los 15 min, el aviso a los 5 y quitar el punto al empezar), que se rehace cuando EventKit dice que algo cambió
// (`EKEventStoreChanged`) y al cambiar el día o despertar el Mac. El usuario decide el permiso: la app solo lo pide cuando pulsa
// «Dar acceso».

/// De dónde salen los eventos. EventKit de verdad en la app; en los tests, uno falso con la misma forma
@MainActor
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    /// Pide el permiso al usuario (el aviso del sistema). Devuelve si se concedió
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    /// Los eventos que tocan entre esas fechas, sin los de los calendarios excluidos, ya sin cancelados ni rechazados
    func events(from start: Date, to end: Date, excluding: Set<String>) -> [CalendarEvent]
    /// Avisa de que algo cambió en Calendario (un evento nuevo, movido o borrado, o una sincronización)
    func onChange(_ handler: @escaping @MainActor () -> Void)
}

@MainActor
final class EventKitSource: CalendarSource {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        // Denegado, restringido por el administrador, o «solo escribir» (que no deja leer)
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func calendars() -> [CalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "", color: Self.color($0.cgColor))
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func events(from start: Date, to end: Date, excluding: Set<String>) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let chosen = store.calendars(for: .event).filter { !excluding.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        return store.events(matching: predicate).compactMap(Self.convert)
    }

    func onChange(_ handler: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate, event.status != .canceled else { return nil }
        // Un evento al que dijiste que no no hace falta recordártelo
        if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined { return nil }
        let id = (event.eventIdentifier ?? event.calendarItemIdentifier) + "@" + String(Int(start.timeIntervalSince1970))
        // Las notas pueden ser enormes: el enlace de la videollamada está al principio
        let texts = [event.url?.absoluteString, event.location, event.notes.map { String($0.prefix(4000)) }].compactMap { $0 }
        return CalendarEvent(
            id: id, title: event.title ?? "Sin título", start: start, end: end, isAllDay: event.isAllDay,
            calendarID: event.calendar.calendarIdentifier, color: color(event.calendar.cgColor), joinURL: MeetingLink.find(in: texts)
        )
    }

    private static func color(_ color: CGColor?) -> CalendarColor {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return .fallback }
        return CalendarColor(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}

@MainActor
@Observable
final class CalendarStore {
    /// Lo que se espera tras un aviso de cambio antes de volver a leer: una sincronización manda muchos seguidos
    static let reloadDelay: Duration = .seconds(1)
    /// Con la pestaña a la vista, lo del momento («en curso») se pone al día cada tanto
    static let tickInterval: Duration = .seconds(60)

    private(set) var access: CalendarAccess
    private(set) var events: [CalendarEvent] = []
    private(set) var calendars: [CalendarInfo] = []
    /// El día elegido con un clic; nil es el del centro de la tira (hoy, en la semana de hoy)
    private(set) var selectedDay: Date?
    private(set) var weekOffset = 0
    /// Algún evento empieza en menos de 15 min: el punto azul de Utilidades
    private(set) var isBadgeOn = false
    /// El momento al que se refiere lo que se enseña
    private(set) var now: Date

    /// Un evento está a punto de empezar. La hora es la de ese momento
    @ObservationIgnored var onNotice: (@MainActor (CalendarEvent, Date) -> Void)?

    @ObservationIgnored private let source: CalendarSource
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let poller = Poller()
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Los eventos que ya avisaron (su identificador, con el inicio) y cuándo empiezan, para podarlos
    @ObservationIgnored private var notified: [String: Date] = [:]
    /// La primera lectura solo apunta lo que ya tocaba: no avisa de lo anterior al arranque
    @ObservationIgnored private var hasEvaluated = false
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isVisible = false

    /// Los nombres de los días y los meses van en español, como el resto de la app; el huso es el del Mac y lo sigue si cambia
    /// (un viaje), y el fin de semana es sábado y domingo
    static func defaultCalendar() -> Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "es")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    init(
        source: CalendarSource, settings: AppSettings, calendar: Calendar = CalendarStore.defaultCalendar(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.settings = settings
        self.calendar = calendar
        self.clock = clock
        now = clock()
        access = source.access
    }

    /// Lo que enseña el módulo ahora
    var snapshot: CalendarSnapshot {
        CalendarSnapshot.make(access: access, events: events, selected: selectedDay, weekOffset: weekOffset, now: now, calendar: calendar)
    }

    var isRunning: Bool { isStarted }

    // MARK: - Ciclo de vida

    /// Empieza a seguir el calendario. En los tests no se llama: sería el calendario de verdad
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Logger.tools.info("Calendario: en marcha")
        source.onChange { [weak self] in self?.scheduleReload() }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            },
            center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            },
            center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            },
            // Al despertar, Calendario puede estar ocupado poniéndose al día: se espera un momento
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            },
        ]
        observeSettings()
        reload()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        wakeTask?.cancel()
        wakeTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        poller.stop()
        isVisible = false
        hasEvaluated = false
    }

    /// La pestaña Utilidades se ve o deja de verse. Con ella a la vista se pone al día todo (el permiso pudo cambiar en Ajustes del
    /// Sistema) y lo del momento cada minuto; al dejar de verse, la tira vuelve a hoy
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard visible else {
            poller.stop()
            selectedDay = nil
            weekOffset = 0
            return
        }
        guard isStarted else { return }
        reload()
        poller.start(interval: Self.tickInterval) { [weak self] _ in self?.tick() }
    }

    // Los ajustes que cambian qué se lee. El valor se lee dentro del seguimiento y lo que se hace con él, fuera
    private func observeSettings() {
        withObservationTracking {
            _ = settings.calendarExcluded
            _ = settings.calendarNotice
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.reload()
                self.observeSettings()
            }
        }
    }

    private func tick() {
        let moment = clock()
        // Solo si cambió el minuto: no se redibuja por nada
        guard calendar.component(.minute, from: moment) != calendar.component(.minute, from: now) || moment.timeIntervalSince(now) > 60 else { return }
        now = moment
    }

    // MARK: - Leer

    /// Lee los eventos de lo que se ve (la semana de la tira y las vecinas) y de las próximas 36 h, que son los que avisan
    func reload() {
        let moment = clock()
        now = moment
        access = source.access
        calendars = source.calendars()
        guard access == .granted else {
            if !events.isEmpty { events = [] }
            isBadgeOn = false
            wakeTask?.cancel()
            return
        }
        // Dos lecturas estrechas, no una que cubra todo entre medias: la semana que se ve (con las vecinas, para los puntos) y las
        // próximas 36 h, que son las que avisan. Pasar muchas semanas no hace crecer ninguna
        let center = CalendarStrip.center(weekOffset: weekOffset, now: moment, calendar: calendar)
        let shownFrom = calendar.date(byAdding: .day, value: -(CalendarStrip.dayCount / 2 + 7), to: center) ?? center
        let shownTo = calendar.date(byAdding: .day, value: CalendarStrip.dayCount / 2 + 8, to: center) ?? center
        let excluded = Set(settings.calendarExcluded)
        var fetched = source.events(from: shownFrom, to: shownTo, excluding: excluded)
        let seen = Set(fetched.map(\.id))
        fetched += source.events(from: calendar.startOfDay(for: moment), to: moment.addingTimeInterval(36 * 3600), excluding: excluded)
            .filter { !seen.contains($0.id) }
        fetched.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        if fetched != events { events = fetched }
        evaluate(at: moment)
    }

    // EventKit avisa varias veces seguidas al sincronizar: una sola lectura
    private func scheduleReload() {
        guard isStarted, reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadDelay, tolerance: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            reloadTask = nil
            reload()
        }
    }

    // MARK: - Avisos

    /// El punto azul y los avisos que tocan, y la próxima espera
    private func evaluate(at moment: Date) {
        let due = CalendarTimeline.dueNotices(events: events, now: moment, notified: Set(notified.keys))
        for event in due { notified[event.id] = event.start }
        notified = notified.filter { $0.value > moment.addingTimeInterval(-24 * 3600) }
        // La primera vez solo apunta lo que ya tocaba al arrancar
        let announce = hasEvaluated
        hasEvaluated = true
        let badge = CalendarTimeline.isBadgeOn(events: events, at: moment)
        if badge != isBadgeOn { isBadgeOn = badge }
        if announce, settings.calendarNotice, access == .granted {
            for event in due {
                Logger.tools.info("Calendario: aviso")
                onNotice?(event, moment)
            }
        }
        scheduleWake(after: moment)
    }

    // Una sola espera hasta la próxima hora que importa. `Task.sleep` cuenta también el rato que el Mac duerme
    private func scheduleWake(after moment: Date) {
        wakeTask?.cancel()
        wakeTask = nil
        guard isStarted, let wake = CalendarTimeline.nextWake(events: events, after: moment) else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSince(moment))), tolerance: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let current = clock()
            now = current
            evaluate(at: current)
        }
    }

    // MARK: - Lo que se pulsa

    /// Elige el día `index` de la tira (0 a 6)
    func select(dayAt index: Int) {
        let days = snapshot.days
        guard days.indices.contains(index) else { return }
        selectedDay = days[index].date
        now = clock()
    }

    /// Pasa de semana: la tira se centra en hoy más (o menos) 7 días y elige ese día
    func shiftWeek(_ delta: Int) {
        weekOffset += delta
        selectedDay = nil
        reload()
    }

    /// «Dar acceso»: pide el permiso la primera vez. Si ya se denegó, el sistema no vuelve a preguntar: devuelve false y hay que
    /// abrir Ajustes del Sistema (`openPrivacySettings`)
    @discardableResult
    func requestAccess() async -> Bool {
        guard access == .notDetermined else { return access == .granted }
        let granted = await source.requestAccess()
        reload()
        return granted
    }

    /// Ajustes del Sistema › Privacidad y seguridad › Calendarios
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }

    /// Abre el enlace de una videollamada. Se vuelve a comprobar con `MeetingLink` aunque ya lo estuviera: es lo único que abre
    /// algo escrito por otra persona
    func join(_ url: URL) {
        guard MeetingLink.isMeeting(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Abre la app Calendario
    static func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    #if DEBUG
    /// Para el snapshot de la isla: eventos inventados, sin tocar el calendario
    func injectDemo() {
        func event(_ title: String, hour: Int, minutes: Int = 60, color: CalendarColor, join: Bool = false, day: Int = 0, allDay: Bool = false) -> CalendarEvent {
            let start = calendar.date(byAdding: .day, value: day, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now) ?? now
            return CalendarEvent(
                id: "demo-\(title)", title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay,
                calendarID: "demo", color: color, joinURL: join ? URL(string: "https://meet.google.com/abc-defg-hij") : nil
            )
        }
        beforeDemo = (access, events)
        access = .granted
        let hour = calendar.component(.hour, from: now)
        events = [
            event("Revisión del sprint", hour: max(hour - 1, 0), minutes: 120, color: CalendarColor(red: 0.3, green: 0.55, blue: 1), join: true),
            event("Almuerzo con Ana", hour: min(hour + 2, 23), color: CalendarColor(red: 0.3, green: 0.8, blue: 0.45)),
            event("Cumpleaños de Luis", hour: 0, color: CalendarColor(red: 1, green: 0.6, blue: 0.2), day: 2, allDay: true),
            event("Dentista", hour: 10, color: CalendarColor(red: 0.9, green: 0.3, blue: 0.35), day: -1),
            event("Demo del cliente", hour: 9, color: CalendarColor(red: 0.3, green: 0.55, blue: 1), day: 1),
        ]
    }

    @ObservationIgnored private var beforeDemo: (CalendarAccess, [CalendarEvent])?

    /// Quita lo inyectado y devuelve lo que se había leído de verdad
    func resetInjected() {
        guard let beforeDemo else { return }
        (access, events) = beforeDemo
        self.beforeDemo = nil
    }
    #endif
}
