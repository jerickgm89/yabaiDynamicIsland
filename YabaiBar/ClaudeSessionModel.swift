import Foundation

// Lógica pura del módulo Claude Code: de los archivos de `~/.claude/sessions` y de los eventos de los hooks a las sesiones que
// enseña la isla, con su estado: trabajando, esperando tu respuesta o en reposo.

/// Lo que dice `~/.claude/sessions/<pid>.json` de una sesión abierta. Es un formato que Claude Code no documenta: solo se
/// necesita el pid y el id de la sesión, y lo demás es opcional, para que un campo nuevo o uno que desaparece no lo rompa.
/// Los `.key` que hay al lado llevan un token y nunca se leen
struct ClaudeSessionRecord: Equatable, Sendable {
    var pid: Int32
    var sessionID: String
    var cwd: String
    /// El título de la sesión
    var name: String
    /// `busy` o `idle`
    var status: String
    /// `claude-desktop` en las sesiones de la app de Claude
    var entrypoint: String
    /// Cuándo arrancó el proceso, como lo escribe `ps`, en UTC: «Thu Nov 12 23:06:09 2026»
    var procStart: String
    var statusUpdatedAt: Date?

    static func parse(_ data: Data) -> ClaudeSessionRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
              let session = object["sessionId"] as? String, !session.isEmpty else { return nil }
        func text(_ key: String) -> String { object[key] as? String ?? "" }
        return ClaudeSessionRecord(
            pid: pid, sessionID: session, cwd: text("cwd"), name: text("name"), status: text("status"),
            entrypoint: text("entrypoint"), procStart: text("procStart"),
            statusUpdatedAt: (object["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        )
    }

    /// El nombre de la carpeta donde corre
    var folder: String { ClaudeFolder.name(of: cwd) }

    /// Los valores de `status` que se conocen. Claude Code puede escribir otros: se registran la primera vez que salen
    static let knownStatuses: Set<String> = ["busy", "idle", "shell"]

    var origin: ClaudeOrigin { entrypoint == ClaudeOrigin.desktopEntrypoint ? .desktopApp : .terminal }

    /// `procStart` como fecha. nil si no se entiende
    var startDate: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = true
        return formatter.date(from: procStart)
    }
}

/// De dónde viene una sesión: la app de Claude o una terminal (o un editor)
enum ClaudeOrigin: Equatable, Sendable {
    static let desktopEntrypoint = "claude-desktop"
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    case desktopApp, terminal

    var label: String {
        switch self {
        case .desktopApp: "App de Claude"
        case .terminal: "Terminal"
        }
    }
}

enum ClaudeSessionState: Equatable, Sendable {
    case working, waiting, idle
}

struct ClaudeSession: Equatable, Sendable, Identifiable {
    var id: String
    var pid: Int32
    var folder: String
    var title: String
    var origin: ClaudeOrigin
    var state: ClaudeSessionState
}

/// Lo que sale de un evento de un hook y la isla enseña
enum ClaudeOutcome: Equatable, Sendable {
    /// La sesión pide algo: permiso, una respuesta, que apruebes un plan. `message` es lo que dice Claude Code, si dice algo
    case asks(sessionID: String, cwd: String, message: String)
    /// La sesión terminó lo que hacía, tras `duration` trabajando (nil si no se sabe desde cuándo)
    case finished(sessionID: String, cwd: String, duration: TimeInterval?)
}

// El estado de las sesiones a partir de los eventos de los hooks. Un archivo de sesión dice si está ocupada o en reposo, pero
// no si espera tu respuesta: eso solo lo dicen los hooks. Pedir algo es un `Notification` de unos tipos, o un `PreToolUse` de
// AskUserQuestion o ExitPlanMode; deja de esperar con el primer `PostToolUse` (ya se respondió y la herramienta corre), un
// `UserPromptSubmit` o un `Stop`. `Stop` no llega si interrumpes a Claude: entonces el estado dura hasta tu siguiente
// mensaje, hasta que la sesión se cierre o hasta que pasen `expiry` minutos. No se usa que el archivo diga `idle`: no se sabe
// si durante un permiso pendiente lo dice, y quitar una pregunta que sigue en pie es peor que dejar una de más.
struct ClaudeSessionStates: Equatable, Sendable {
    /// Los `Notification` que son una petición. `idle_prompt` (terminó hace un minuto) o `auth_success` no lo son
    static let askingNotifications: Set<String> = [
        "permission_prompt", "worker_permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]
    static let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    static let expiry: TimeInterval = 30 * 60
    /// Como mucho tantas sesiones recordadas: cualquier proceso puede mandar avisos con ids inventados y esto solo se poda al
    /// leer la carpeta
    static let maxTracked = 64

    struct Waiting: Equatable, Sendable {
        var since: Date
        var cwd: String
    }

    private(set) var waiting: [String: Waiting] = [:]
    private var workingSince: [String: Date] = [:]

    var waitingCount: Int { waiting.count }

    /// Lo que cambia un evento. Pedir algo dos veces seguidas (un `PreToolUse` y su `Notification`) solo avisa la primera
    mutating func apply(_ event: ClaudeHookEvent, at now: Date) -> ClaudeOutcome? {
        let id = event.sessionID
        switch event.name {
        case .notification:
            guard Self.askingNotifications.contains(event.kind) else { return nil }
            return ask(id, cwd: event.cwd, message: event.message, at: now)
        case .preToolUse:
            guard Self.askingTools.contains(event.kind) else { return nil }
            return ask(id, cwd: event.cwd, message: event.kind == "ExitPlanMode" ? "Tiene un plan por aprobar" : "Te hace una pregunta", at: now)
        case .postToolUse:
            waiting[id] = nil
            if workingSince[id] == nil { workingSince[id] = now }
            trim()
            return nil
        case .userPromptSubmit:
            waiting[id] = nil
            workingSince[id] = now
            trim()
            return nil
        case .stop:
            waiting[id] = nil
            let started = workingSince.removeValue(forKey: id)
            return .finished(sessionID: id, cwd: event.cwd, duration: started.map { now.timeIntervalSince($0) })
        }
    }

    private mutating func ask(_ id: String, cwd: String, message: String, at now: Date) -> ClaudeOutcome? {
        let already = waiting[id] != nil
        waiting[id] = Waiting(since: waiting[id]?.since ?? now, cwd: cwd)
        trim()
        return already ? nil : .asks(sessionID: id, cwd: cwd, message: message)
    }

    private mutating func trim() {
        if waiting.count > Self.maxTracked {
            for (id, _) in waiting.sorted(by: { $0.value.since < $1.value.since }).prefix(waiting.count - Self.maxTracked) {
                waiting[id] = nil
            }
        }
        if workingSince.count > Self.maxTracked {
            for (id, _) in workingSince.sorted(by: { $0.value < $1.value }).prefix(workingSince.count - Self.maxTracked) {
                workingSince[id] = nil
            }
        }
    }

    /// Olvida lo que pasó hace más de `expiry` y, si se sabe qué sesiones hay abiertas (`records`), lo de las que ya no están.
    /// `records` es nil cuando no se pudo leer la carpeta: entonces solo cuenta el tiempo
    mutating func prune(records: [ClaudeSessionRecord]?, at now: Date) {
        let open = records.map { Set($0.map(\.sessionID)) }
        waiting = waiting.filter { now.timeIntervalSince($0.value.since) < Self.expiry && (open?.contains($0.key) ?? true) }
        workingSince = workingSince.filter { now.timeIntervalSince($0.value) < 24 * 3600 && (open?.contains($0.key) ?? true) }
    }

    func state(of record: ClaudeSessionRecord) -> ClaudeSessionState {
        if waiting[record.sessionID] != nil { return .waiting }
        // `shell` (un comando en marcha) es trabajo. Lo demás que no sea `busy` cuenta como reposo
        return record.status == "busy" || record.status == "shell" ? .working : .idle
    }

    /// Las sesiones para enseñar: las que esperan primero, después las que trabajan, y por carpeta
    func sessions(from records: [ClaudeSessionRecord]) -> [ClaudeSession] {
        records
            .map { ClaudeSession(id: $0.sessionID, pid: $0.pid, folder: $0.folder, title: $0.name, origin: $0.origin, state: state(of: $0)) }
            .sorted { lhs, rhs in
                if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
                if lhs.folder != rhs.folder { return lhs.folder.localizedCaseInsensitiveCompare(rhs.folder) == .orderedAscending }
                return lhs.id < rhs.id
            }
    }
}

private extension ClaudeSessionState {
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .idle: 2
        }
    }
}

// Qué app abre una sesión al pulsarla: la primera app normal entre los procesos de los que cuelga. Para las de la app de Claude
// es Claude; para las de una terminal, la terminal o el editor
enum ProcessAncestry {
    static func firstApp(
        from pid: Int32, maxDepth: Int = 12, parent: (Int32) -> Int32?, isApp: (Int32) -> Bool
    ) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            guard let next = parent(current), next > 1, next != current else { return nil }
            if isApp(next) { return next }
            current = next
        }
        return nil
    }
}

enum ClaudeRows {
    static let connectID = "claude:connect"
    static let noneID = "claude:none"

    static func rowID(forSession id: String) -> String { "session:\(id)" }
    static func sessionID(ofRow row: String) -> String? { row.hasPrefix("session:") ? String(row.dropFirst("session:".count)) : nil }

    /// Las filas del módulo: hasta 3 sesiones y, sin los hooks conectados, una invitación a conectarlos. `connected` es nil
    /// hasta saberlo
    static func content(of sessions: [ClaudeSession]?, connected: Bool?) -> ModuleRowsContent {
        guard let sessions else { return ModuleRowsContent(summary: "", rows: [], notice: nil) }
        let invitation = connected == false
        // Con la invitación, la tercera fila es suya
        let capacity = invitation ? ModuleRowLayout.maxRows - 1 : ModuleRowLayout.maxRows
        var rows = sessions.prefix(capacity).map { session in
            ModuleRow(
                id: rowID(forSession: session.id), leading: .dot(session.state.tone), title: session.folder,
                detail: session.title, trailing: session.state.label, tone: session.state.tone, primaryAction: .activate
            )
        }
        if sessions.isEmpty {
            rows = [ModuleRow(id: noneID, title: "Ninguna sesión abierta", isDimmed: true)]
        }
        if invitation {
            rows.append(
                ModuleRow(
                    id: connectID, title: "No avisa de las preguntas", actions: [.connect], isDimmed: true,
                    showsActionsAlways: true
                )
            )
        }
        let summary = sessions.isEmpty ? "" : sessions.count == 1 ? "1 sesión" : sessions.count > capacity ? "\(capacity) de \(sessions.count)" : "\(sessions.count) sesiones"
        return ModuleRowsContent(summary: summary, rows: rows, notice: nil)
    }
}

private extension ClaudeSessionState {
    var label: String {
        switch self {
        case .working: "Trabajando"
        case .waiting: "Pregunta"
        case .idle: "En reposo"
        }
    }

    var tone: RowTone {
        switch self {
        case .working: .active
        case .waiting: .attention
        case .idle: .neutral
        }
    }
}

/// Deja pasar como mucho `limit` avisos en cada ventana de `window` segundos: lo demás se descarta
struct EventRateLimiter: Equatable, Sendable {
    let limit: Int
    let window: TimeInterval
    private var stamps: [Date] = []

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(at now: Date) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

/// El aviso de la isla cerrada para lo que hace una sesión de Claude Code
struct ClaudePeek: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case asks, finished
    }

    /// Lo mínimo que tiene que trabajar para avisar de que terminó: no se avisa de cada respuesta corta
    static let minimumWork: TimeInterval = 30

    var kind: Kind
    var folder: String
    var detail: String

    // El ala de la isla cerrada es estrecha y recorta el final: el título es lo que pasa y el subtítulo empieza por la carpeta,
    // que es lo que dice de qué sesión se trata
    var title: String { kind == .asks ? "Claude pregunta" : "Claude terminó" }
    var subtitle: String { folder + " · " + detail }

    /// nil si el evento no merece un aviso: terminar sin que esté activado el ajuste, o tras menos de 30 s
    static func make(for outcome: ClaudeOutcome, notifyFinished: Bool) -> ClaudePeek? {
        switch outcome {
        case .asks(_, let cwd, let message):
            return ClaudePeek(kind: .asks, folder: ClaudeFolder.name(of: cwd), detail: message.isEmpty ? "Espera tu respuesta" : message)
        case .finished(_, let cwd, let duration):
            guard notifyFinished, let duration, duration >= minimumWork else { return nil }
            return ClaudePeek(kind: .finished, folder: ClaudeFolder.name(of: cwd), detail: "tras \(spoken(duration))")
        }
    }

    /// «45 s», «3 min», «1 h 5 min»
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
