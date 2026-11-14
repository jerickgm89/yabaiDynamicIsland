import Foundation

// Lo que Claude Code le cuenta a YabaiBar con sus hooks, y cómo viaja de un proceso a otro. Lo compilan la app y el ayudante
// `yb` (que lo manda), así que no depende de AppKit ni de nada de la app.

/// Un evento de los hooks de Claude Code, quedándose solo con lo que YabaiBar necesita. Nunca viaja el texto de lo que
/// escribes (`prompt`) ni lo que responde Claude (`last_assistant_message`)
struct ClaudeHookEvent: Equatable, Sendable {
    enum Name: String, Sendable, CaseIterable {
        case notification = "Notification"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case userPromptSubmit = "UserPromptSubmit"
        case stop = "Stop"
    }

    var name: Name
    var sessionID: String
    /// La carpeta donde corre la sesión
    var cwd: String
    /// El `notification_type` de un `Notification` o el `tool_name` de un `PreToolUse` o `PostToolUse`; vacío en los demás
    var kind: String = ""
    /// El `message` de un `Notification`
    var message: String = ""
}

enum ClaudeFolder {
    /// El nombre de la carpeta de una ruta: «/Users/ana/proyectos/web» → «web». Sin carpeta, «Claude Code»
    static func name(of cwd: String) -> String {
        let last = URL(filePath: cwd).lastPathComponent
        return last.isEmpty || last == "/" ? (cwd.isEmpty ? "Claude Code" : cwd) : last
    }
}

enum ClaudeHookText {
    /// Lo que llega de fuera se limpia antes de usarlo: sin saltos de línea ni caracteres de control, y como mucho `limit`
    static func clean(_ text: String, limit: Int = 160) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }
}

// El JSON que cada hook recibe por stdin. Los campos que no se usan se ignoran, y solo hace falta el nombre del evento y la
// sesión: si Claude Code añade o cambia campos, sigue valiendo
enum ClaudeHookInput {
    // Un `PostToolUse` lleva la respuesta de la herramienta, que puede ser un archivo entero: el límite es holgado para no perder
    // el evento que dice que ya respondiste un permiso
    static let maxInputBytes = 32_000_000

    /// nil si no es un evento que nos interese o no se entiende
    static func parse(_ data: Data) -> ClaudeHookEvent? {
        guard data.count <= maxInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = object["hook_event_name"] as? String, let name = ClaudeHookEvent.Name(rawValue: eventName),
              let session = object["session_id"] as? String, !session.isEmpty else { return nil }
        func text(_ key: String, limit: Int = 160) -> String { ClaudeHookText.clean(object[key] as? String ?? "", limit: limit) }
        // De la ruta de la carpeta solo viaja su nombre: es lo único que enseña la isla
        var event = ClaudeHookEvent(
            name: name, sessionID: ClaudeHookText.clean(session, limit: 80),
            cwd: ClaudeFolder.name(of: text("cwd", limit: 400))
        )
        switch name {
        case .notification:
            event.kind = text("notification_type", limit: 60)
            event.message = text("message")
        case .preToolUse, .postToolUse:
            event.kind = text("tool_name", limit: 60)
        case .userPromptSubmit, .stop:
            break
        }
        return event
    }
}

// El aviso de un proceso a otro: una notificación distribuida con un diccionario de textos. Cualquier proceso puede mandar una,
// así que lo que llega se valida: solo se conocen los tipos de la lista, los campos son textos de longitud acotada y nada de lo
// que dice sirve para abrir una app (solo para activar, con un clic del usuario, una que ya esté abierta: los avisos de la terminal
// dicen de qué app vienen): el origen de una sesión de Claude se averigua en la app, desde su pid
struct AvisoMessage: Equatable, Sendable {
    static let notificationName = "com.jerickdev.yabaibar.aviso"
    static let maxFields = 12

    enum Kind: String, Sendable {
        case claudeHook = "claude-hook"
        /// Un comando largo que terminó o un `yb aviso` (ver TerminalNotice.swift)
        case terminal
    }

    var kind: Kind
    var fields: [String: String]

    var userInfo: [String: String] { fields.merging(["kind": kind.rawValue]) { _, kind in kind } }

    init(kind: Kind, fields: [String: String]) {
        self.kind = kind
        self.fields = fields
    }

    /// nil si no es un aviso nuestro bien formado
    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo, userInfo.count <= Self.maxFields + 1,
              let rawKind = userInfo["kind"] as? String, let kind = Kind(rawValue: rawKind) else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, key.count <= 40, let text = value as? String, text.count <= 500 else { return nil }
            if key != "kind" { fields[key] = text }
        }
        self.init(kind: kind, fields: fields)
    }

    init(_ event: ClaudeHookEvent) {
        self.init(
            kind: .claudeHook,
            fields: [
                "event": event.name.rawValue, "session": event.sessionID, "cwd": event.cwd, "type": event.kind,
                "message": event.message,
            ]
        )
    }

    /// El evento de Claude Code que lleva, si lo lleva y se entiende
    var claudeEvent: ClaudeHookEvent? {
        guard kind == .claudeHook, let name = fields["event"].flatMap(ClaudeHookEvent.Name.init(rawValue:)),
              let session = fields["session"], !session.isEmpty else { return nil }
        // Cualquier proceso puede mandar un aviso: lo que llega se limpia otra vez aquí, no solo en `yb`
        func clean(_ key: String, limit: Int) -> String { ClaudeHookText.clean(fields[key] ?? "", limit: limit) }
        return ClaudeHookEvent(
            name: name, sessionID: ClaudeHookText.clean(session, limit: 80), cwd: clean("cwd", limit: 100),
            kind: clean("type", limit: 60), message: clean("message", limit: 160)
        )
    }
}
