import Foundation
import Observation

// El módulo Avisos de la pestaña Desarrollador: los 10 últimos avisos de la isla cerrada, vengan de la terminal, de Claude Code o
// de Git, por si no los viste (la isla los enseña unos segundos). Solo en memoria: al reiniciar la app se vacía. Un clic en uno
// lleva a su origen: la app de la terminal, la sesión de Claude o la página del repositorio.

/// Un aviso guardado
struct NoticeEntry: Equatable, Identifiable, Sendable {
    enum Origin: Equatable, Sendable {
        /// La app en que corre la terminal (su identificador), si se averiguó
        case terminal(bundleID: String?)
        case claude(sessionID: String)
        /// Un repositorio, por su nombre
        case git(repo: String)
        /// Un evento del calendario: un clic abre Calendario
        case calendar
    }

    var id = UUID().uuidString
    var date: Date
    var tone: RowTone
    var title: String
    var detail: String
    var origin: Origin
}

@MainActor
@Observable
final class NoticeLog {
    static let capacity = 10

    /// Del más nuevo al más viejo
    private(set) var entries: [NoticeEntry] = []

    /// Un aviso igual al último de hace menos de un minuto no se apunta otra vez: solo pone al día su hora (un script que avisa en
    /// bucle no desaloja los de Claude y Git)
    static let repeatWindow: TimeInterval = 60

    func record(_ entry: NoticeEntry) {
        if let last = entries.first, last.title == entry.title, last.detail == entry.detail, last.origin == entry.origin,
           entry.date.timeIntervalSince(last.date) < Self.repeatWindow {
            entries[0].date = entry.date
            return
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    func entry(withID id: String) -> NoticeEntry? {
        entries.first { $0.id == id }
    }

    #if DEBUG
    /// Lo que había antes de la demo, para devolverlo
    @ObservationIgnored private var beforeDemo: [NoticeEntry]?

    /// Para el snapshot de la isla: avisos inventados de cada origen
    func injectDemo(now: Date = Date()) {
        if beforeDemo == nil { beforeDemo = entries }
        entries = [
            NoticeEntry(date: now, tone: .alert, title: "npm falló", detail: "código 1 · 2 min · Ghostty", origin: .terminal(bundleID: nil)),
            NoticeEntry(date: now.addingTimeInterval(-600), tone: .attention, title: "Claude pregunta", detail: "tienda · Necesita tu permiso", origin: .claude(sessionID: "demo")),
            NoticeEntry(date: now.addingTimeInterval(-3600), tone: .attention, title: "3 commits sin push", detail: "tienda", origin: .git(repo: "tienda")),
            NoticeEntry(date: now.addingTimeInterval(-7200), tone: .ok, title: "make terminó", detail: "45 s · Terminal", origin: .terminal(bundleID: nil)),
        ]
    }

    /// Quita lo inyectado y devuelve los avisos de verdad
    func resetInjected() {
        guard let beforeDemo else { return }
        entries = beforeDemo
        self.beforeDemo = nil
    }
    #endif
}

extension GitNotice {
    var rowTone: RowTone {
        switch kind {
        case .ci(.failed): .alert
        case .ci: .ok
        case .unpushed, .uncommitted, .unreleased: .attention
        }
    }

    func entry(date: Date) -> NoticeEntry {
        NoticeEntry(date: date, tone: rowTone, title: title, detail: repo, origin: .git(repo: repo))
    }
}

extension ClaudePeek {
    func entry(sessionID: String, date: Date) -> NoticeEntry {
        NoticeEntry(date: date, tone: kind == .asks ? .attention : .ok, title: title, detail: subtitle, origin: .claude(sessionID: sessionID))
    }
}

enum NoticeRows {
    /// Lo que hace un clic en un aviso: ir a la app de la terminal o a la sesión de Claude, o abrir la página del repositorio. Sin
    /// origen conocido, nada
    static func action(for origin: NoticeEntry.Origin) -> RowAction? {
        switch origin {
        case .terminal(let bundleID): bundleID == nil ? nil : .activate
        case .claude, .calendar: .activate
        case .git: .open
        }
    }

    /// Hasta 3 avisos, los más nuevos, con la hora a la derecha (`time` la da formateada; la hora fija no se queda vieja)
    static func content(of entries: [NoticeEntry], time: (Date) -> String) -> ModuleRowsContent {
        guard !entries.isEmpty else {
            return ModuleRowsContent(
                summary: "", rows: [],
                notice: .init(title: "Sin avisos todavía", subtitle: "Aquí salen los de la terminal, Claude Code y Git.")
            )
        }
        let rows = entries.prefix(ModuleRowLayout.maxRows).map { entry -> ModuleRow in
            let action = action(for: entry.origin)
            return ModuleRow(
                id: entry.id, leading: .dot(entry.tone), title: entry.title, detail: entry.detail, trailing: time(entry.date),
                actions: action.map { [$0] } ?? [], primaryAction: action
            )
        }
        let count = entries.count
        let summary = count > ModuleRowLayout.maxRows ? "\(ModuleRowLayout.maxRows) de \(count)" : count == 1 ? "1 aviso" : "\(count) avisos"
        return ModuleRowsContent(summary: summary, rows: Array(rows), notice: nil)
    }
}
