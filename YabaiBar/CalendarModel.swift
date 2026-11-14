import CoreGraphics
import Foundation

// Lógica pura del módulo Calendario de Utilidades (fase 42): la tira de 7 días, qué eventos se enseñan de un día y cuál está en
// curso, el enlace de videollamada, cuándo avisar y dónde está cada cosa para dibujarla y resolver los clics. Nada de aquí usa
// EventKit ni AppKit: `CalendarStore` convierte los eventos de verdad a `CalendarEvent`.

/// El color de un calendario, en sRGB
struct CalendarColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let fallback = CalendarColor(red: 0.35, green: 0.6, blue: 1)
}

struct CalendarEvent: Equatable, Identifiable, Sendable {
    /// El del evento y su inicio: una serie repetida tiene el mismo identificador en cada aparición
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var color: CalendarColor
    /// El enlace de videollamada, ya validado por `MeetingLink`
    var joinURL: URL?

    /// Los de todo el día no están «en curso»: duran el día entero
    func isInProgress(at now: Date) -> Bool {
        !isAllDay && start <= now && now < end
    }
}

/// Un calendario del usuario, para elegir cuáles se ven en Ajustes
struct CalendarInfo: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    /// La cuenta a la que pertenece (iCloud, Google…)
    var account: String
    var color: CalendarColor
}

// MARK: - Enlaces de videollamada

enum MeetingLink {
    private static let maxLength = 500

    /// El primer enlace de Meet, Zoom o Teams de unos textos (la URL del evento, el lugar y las notas). Solo https, solo esos
    /// servidores y sin usuario en la dirección: lo escribe quien te invita, y el botón «Unirse» lo abre con un clic
    static func find(in texts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                if let url = match.url, isMeeting(url) { return url }
            }
        }
        return nil
    }

    static func isMeeting(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.absoluteString.count <= maxLength, let host = url.host?.lowercased(), matches(host, #"^[a-z0-9.-]+$"#),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, isPlain(path) else { return false }
        func hosted(by domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "meet.google.com" {
            // «abc-defg-hij», o `lookup/…` de un enlace corto
            return matches(path, #"^/([a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/[A-Za-z0-9_-]+)$"#)
        }
        if hosted(by: "zoom.us") || hosted(by: "zoomgov.com") {
            return matches(path, #"^/(j|my|wc)/[A-Za-z0-9._/-]+$"#)
        }
        // La ruta de Teams lleva el identificador de la reunión con caracteres escapados (`%3a`, `%40`)
        if host == "teams.microsoft.com" { return matches(path, #"^/(l/meetup-join|l/meeting|meet)/[A-Za-z0-9%._~@:/+=-]+$"#) }
        if host == "teams.live.com" { return matches(path, #"^/(meet|l/meetup-join)/[A-Za-z0-9%._~@:/+=-]+$"#) }
        return false
    }

    /// Sin `..`, `//`, barras invertidas ni puntos y barras escapados: un navegador los resuelve y la ruta acabaría en otra página del
    /// mismo servidor
    private static func isPlain(_ path: String) -> Bool {
        let lowered = path.lowercased()
        guard !path.contains("\\"), !path.contains("//"), !lowered.contains("%2e"), !lowered.contains("%2f"), !lowered.contains("%5c")
        else { return false }
        return !path.split(separator: "/").contains("..") && !path.split(separator: "/").contains(".")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - La tira de días

struct CalendarDay: Equatable, Identifiable, Sendable {
    var date: Date
    var number: Int
    /// La inicial del día sobre el número («L»), y para hoy su nombre corto («LUN»)
    var label: String
    var isToday: Bool
    var isWeekend: Bool
    var isSelected: Bool
    var hasEvents: Bool

    var id: Date { date }
}

enum CalendarStrip {
    static let dayCount = 7

    /// El día del centro de la tira: hoy, o hoy más `weekOffset` semanas
    static func center(weekOffset: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 7 * weekOffset, to: today) ?? today
    }

    /// Los 7 días centrados en `center` (3 antes, el día, 3 después). `selected` es el que enseña sus eventos
    static func days(center: Date, selected: Date, events: [CalendarEvent], now: Date, calendar: Calendar) -> [CalendarDay] {
        let today = calendar.startOfDay(for: now)
        let selectedDay = calendar.startOfDay(for: selected)
        return (-(dayCount / 2)...(dayCount / 2)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: center) else { return nil }
            let day = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: day) - 1
            let isToday = day == today
            return CalendarDay(
                date: day, number: calendar.component(.day, from: day),
                label: isToday ? shortName(weekday: weekday, calendar: calendar) : initial(weekday: weekday, calendar: calendar),
                isToday: isToday, isWeekend: calendar.isDateInWeekend(day), isSelected: day == selectedDay,
                hasEvents: events.contains { CalendarAgenda.touches($0, day: day, calendar: calendar) }
            )
        }
    }

    /// «NOVIEMBRE», y con el año si no es el actual
    static func monthTitle(center: Date, now: Date, calendar: Calendar) -> String {
        let month = calendar.component(.month, from: center)
        let name = calendar.monthSymbols[(month - 1) % calendar.monthSymbols.count].uppercased()
        let year = calendar.component(.year, from: center)
        return year == calendar.component(.year, from: now) ? name : "\(name) \(year)"
    }

    private static func initial(weekday: Int, calendar: Calendar) -> String {
        calendar.veryShortWeekdaySymbols[weekday % calendar.veryShortWeekdaySymbols.count].uppercased()
    }

    /// «LUN»: sin el punto que algunos idiomas añaden a la abreviatura
    private static func shortName(weekday: Int, calendar: Calendar) -> String {
        calendar.shortWeekdaySymbols[weekday % calendar.shortWeekdaySymbols.count].uppercased().replacingOccurrences(of: ".", with: "")
    }
}

// MARK: - Los eventos de un día

struct CalendarAgendaItem: Equatable, Identifiable, Sendable {
    var event: CalendarEvent
    /// «14:30», o «Todo el día»
    var timeText: String
    var isInProgress: Bool

    var id: String { event.id }
}

enum CalendarAgenda {
    /// Cuántos eventos caben bajo la tira
    static let maxItems = 2

    /// El evento toca ese día (los de todo el día acaban a medianoche, sin contarla)
    static func touches(_ event: CalendarEvent, day: Date, calendar: Calendar) -> Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return event.start < next && (event.end > day || event.start >= day && event.start < next)
    }

    /// Los eventos que se enseñan de `day`: los de todo el día primero y después por hora. En el día de hoy, los que ya acabaron no
    /// salen, y el que está en curso va marcado
    static func items(for day: Date, events: [CalendarEvent], now: Date, calendar: Calendar, limit: Int = maxItems) -> [CalendarAgendaItem] {
        let dayStart = calendar.startOfDay(for: day)
        let isToday = dayStart == calendar.startOfDay(for: now)
        let shown = events
            .filter { touches($0, day: dayStart, calendar: calendar) && !(isToday && !$0.isAllDay && $0.end <= now) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        // Con reuniones ese día, solo un evento de todo el día: un festivo y un cumpleaños no esconden lo que empieza pronto
        let timed = shown.filter { !$0.isAllDay }
        let ordered = timed.isEmpty ? shown : Array(shown.filter(\.isAllDay).prefix(1)) + timed
        return ordered.prefix(limit)
            .map { CalendarAgendaItem(event: $0, timeText: time($0, on: dayStart, calendar: calendar), isInProgress: $0.isInProgress(at: now)) }
    }

    /// «14:30», «Todo el día», o «Sigue» si el evento con hora empezó otro día
    static func time(_ event: CalendarEvent, on day: Date, calendar: Calendar) -> String {
        guard !event.isAllDay else { return "Todo el día" }
        return event.start < calendar.startOfDay(for: day) ? "Sigue" : clock(event.start, calendar: calendar)
    }

    /// «14:30», de 24 h
    static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - Lo que enseña el módulo

enum CalendarAccess: Equatable, Sendable {
    case granted, notDetermined, denied
}

struct CalendarSnapshot: Equatable, Sendable {
    var access: CalendarAccess
    var month: String
    var days: [CalendarDay]
    var items: [CalendarAgendaItem]
    /// Sin eventos ese día: «Nada para hoy»
    var emptyTitle: String?
    /// Hoy sin eventos: lo primero de mañana
    var upNext: CalendarAgendaItem?
    var isShowingToday: Bool

    /// Sin permiso las fechas se ven igual (no necesitan permiso) y no hay eventos
    static func make(
        access: CalendarAccess, events: [CalendarEvent], selected: Date?, weekOffset: Int, now: Date, calendar: Calendar
    ) -> CalendarSnapshot {
        let center = CalendarStrip.center(weekOffset: weekOffset, now: now, calendar: calendar)
        let selectedDay = calendar.startOfDay(for: selected ?? center)
        let shown = access == .granted ? events : []
        let days = CalendarStrip.days(center: center, selected: selectedDay, events: shown, now: now, calendar: calendar)
        let items = CalendarAgenda.items(for: selectedDay, events: shown, now: now, calendar: calendar)
        let isToday = selectedDay == calendar.startOfDay(for: now)
        var emptyTitle: String?
        var upNext: CalendarAgendaItem?
        if access == .granted, items.isEmpty {
            emptyTitle = isToday ? "Nada para hoy" : "Nada ese día"
            if isToday, let tomorrow = calendar.date(byAdding: .day, value: 1, to: selectedDay) {
                upNext = CalendarAgenda.items(for: tomorrow, events: shown, now: now, calendar: calendar, limit: 1).first
            }
        }
        return CalendarSnapshot(
            access: access, month: CalendarStrip.monthTitle(center: center, now: now, calendar: calendar), days: days, items: items,
            emptyTitle: emptyTitle, upNext: upNext, isShowingToday: isToday
        )
    }
}

// MARK: - Cuándo avisar

enum CalendarTimeline {
    /// El punto azul de Utilidades y el aviso se piden con esta antelación
    static let badgeLead: TimeInterval = 15 * 60
    static let noticeLead: TimeInterval = 5 * 60

    /// Los eventos que merecen un aviso: con hora (uno de todo el día no tiene «5 min antes») y que todavía no empezaron
    private static func upcoming(_ events: [CalendarEvent], after now: Date) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.start > now }.sorted { $0.start < $1.start }
    }

    /// El punto azul: algún evento empieza dentro de 15 minutos o menos
    static func isBadgeOn(events: [CalendarEvent], at now: Date) -> Bool {
        upcoming(events, after: now).contains { $0.start.timeIntervalSince(now) <= badgeLead }
    }

    /// Los eventos cuyo aviso (`lead` antes de empezar) ya toca y que todavía no empezaron ni se avisaron (`notified` son sus
    /// identificadores, que llevan el inicio: un evento movido vuelve a avisar). No depende de cuándo se leyó por última vez: ninguna
    /// lectura de por medio (una sincronización, abrir la pestaña) hace perder un aviso, y si el Mac durmió y despierta antes de que
    /// empiece, el aviso llega tarde pero llega
    static func dueNotices(events: [CalendarEvent], now: Date, notified: Set<String>, lead: TimeInterval = noticeLead) -> [CalendarEvent] {
        upcoming(events, after: now).filter {
            $0.start.addingTimeInterval(-lead) <= now && !notified.contains($0.id)
        }
    }

    /// La próxima vez que hay algo que hacer: encender el punto (15 min antes), avisar (`lead` antes) o apagar el punto (al
    /// empezar). nil si no hay eventos por delante
    static func nextWake(events: [CalendarEvent], after now: Date, lead: TimeInterval = noticeLead) -> Date? {
        var next: Date?
        for event in events where !event.isAllDay && event.start > now {
            for moment in [event.start.addingTimeInterval(-badgeLead), event.start.addingTimeInterval(-lead), event.start] where moment > now {
                if next == nil || moment < next! { next = moment }
            }
        }
        return next
    }

    /// «en 5 min · 14:30»
    static func noticeSubtitle(for event: CalendarEvent, at now: Date, calendar: Calendar) -> String {
        let minutes = max(0, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
        let when = minutes == 0 ? "ahora" : "en \(minutes) min"
        return "\(when) · \(CalendarAgenda.clock(event.start, calendar: calendar))"
    }
}

// MARK: - Dónde está cada cosa

/// Lo que se pulsa en el módulo
enum CalendarControl: Hashable, Sendable {
    /// Uno de los 7 días de la tira
    case day(Int)
    /// Una de las filas de eventos: abre Calendario
    case event(Int)
    /// «Unirse» de esa fila
    case join(Int)
    case previousWeek, nextWeek
    /// «Dar acceso» (o abrir Ajustes del Sistema si se denegó)
    case access
}

// El módulo mide 310 × 112: 8 de margen, el mes con las flechas (14), la tira de 7 días (34) y debajo hasta 2 filas de 22
enum CalendarModuleLayout {
    static let padding: CGFloat = 8
    static let headerHeight: CGFloat = 14
    static let stripY: CGFloat = 24
    static let stripHeight: CGFloat = 34
    static let eventsY: CGFloat = 62
    static let rowHeight: CGFloat = 22
    static let arrowSize = CGSize(width: 18, height: 14)
    static let joinSize = CGSize(width: 46, height: 18)
    static let accessSize = CGSize(width: 150, height: 24)

    static func dayFrame(_ index: Int, in size: CGSize) -> CGRect {
        let width = (size.width - 2 * padding) / CGFloat(CalendarStrip.dayCount)
        return CGRect(x: padding + CGFloat(index) * width, y: stripY, width: width, height: stripHeight)
    }

    /// Toda la tira, para el gesto de lado
    static func stripFrame(in size: CGSize) -> CGRect {
        CGRect(x: padding, y: stripY, width: size.width - 2 * padding, height: stripHeight)
    }

    static func eventFrame(_ index: Int, in size: CGSize) -> CGRect {
        CGRect(x: padding, y: eventsY + CGFloat(index) * rowHeight, width: size.width - 2 * padding, height: rowHeight)
    }

    /// «Unirse», pegado al borde derecho de su fila
    static func joinFrame(_ index: Int, in size: CGSize) -> CGRect {
        let row = eventFrame(index, in: size)
        return CGRect(x: row.maxX - joinSize.width - 2, y: row.minY + (row.height - joinSize.height) / 2, width: joinSize.width, height: joinSize.height)
    }

    /// Las flechas de cambiar de semana, a la derecha del mes
    static func previousFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width - padding - 2 * arrowSize.width - 4, y: padding, width: arrowSize.width, height: arrowSize.height)
    }

    static func nextFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width - padding - arrowSize.width, y: padding, width: arrowSize.width, height: arrowSize.height)
    }

    /// «Dar acceso», bajo la tira y centrado
    static func accessFrame(in size: CGSize) -> CGRect {
        CGRect(x: (size.width - accessSize.width) / 2, y: eventsY + 14, width: accessSize.width, height: accessSize.height)
    }

    /// Lo que hay bajo un punto del módulo (origen arriba a la izquierda). `joinable` dice, de cada fila de evento, si lleva «Unirse».
    /// Con un poco de margen en los botones pequeños, para acertarlos fácil
    static func control(at point: CGPoint, in size: CGSize, access: CalendarAccess, joinable: [Bool]) -> CalendarControl? {
        if previousFrame(in: size).insetBy(dx: -3, dy: -4).contains(point) { return .previousWeek }
        if nextFrame(in: size).insetBy(dx: -3, dy: -4).contains(point) { return .nextWeek }
        for index in 0..<CalendarStrip.dayCount where dayFrame(index, in: size).contains(point) { return .day(index) }
        guard access == .granted else {
            return accessFrame(in: size).insetBy(dx: -4, dy: -4).contains(point) ? .access : nil
        }
        for (index, canJoin) in joinable.prefix(CalendarAgenda.maxItems).enumerated() {
            if canJoin, joinFrame(index, in: size).insetBy(dx: -3, dy: -2).contains(point) { return .join(index) }
            if eventFrame(index, in: size).contains(point) { return .event(index) }
        }
        return nil
    }
}

extension IslandExpandedLayout {
    /// El módulo Calendario, en coordenadas de la isla (origen arriba a la izquierda). Solo existe en Utilidades
    func calendarFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard tab == .utilities, let cell = utilityModules.cells.first(where: { $0.module == .calendar }) else { return nil }
        let origin = activityOrigin(islandWidth: islandWidth, topHeight: topHeight)
        return cell.frame.offsetBy(dx: origin.x, dy: origin.y + Self.activityHeight + Self.activityGap)
    }

    /// Lo que hay bajo un punto de la isla del módulo Calendario
    func calendarControl(
        at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat, access: CalendarAccess, joinable: [Bool]
    ) -> CalendarControl? {
        guard let frame = calendarFrame(islandWidth: islandWidth, topHeight: topHeight), frame.contains(point) else { return nil }
        return CalendarModuleLayout.control(
            at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), in: frame.size, access: access, joinable: joinable
        )
    }

    /// Si el punto está sobre la tira de días: el gesto de dos dedos de lado pasa de semana
    func calendarStripContains(_ point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Bool {
        guard let frame = calendarFrame(islandWidth: islandWidth, topHeight: topHeight) else { return false }
        return CalendarModuleLayout.stripFrame(in: frame.size).offsetBy(dx: frame.minX, dy: frame.minY).contains(point)
    }
}

extension Array {
    /// El elemento en esa posición, o nil si no existe
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
