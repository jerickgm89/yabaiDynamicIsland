import Foundation

// Añade y quita los hooks de YabaiBar en el `settings.json` de Claude Code sin tocar los demás. Es lo único de esta fase que
// escribe en la configuración de otra app, así que solo hace lo que se le pide con el botón de Ajustes, y cada cambio es
// añadir sus entradas o quitar exactamente esas: una entrada es suya si su comando es el del ayudante `yb` de esta app.
enum ClaudeHooksEditor {
    /// Cómo está el archivo respecto a YabaiBar
    enum Status: Equatable, Sendable {
        /// Los cinco hooks están y apuntan a este `yb`
        case connected
        case notConnected
        /// Hay hooks de YabaiBar, pero apuntan a otro `yb` (la app se movió) o falta alguno
        case outdated
    }

    enum Failure: Error, Equatable {
        /// No es un JSON que podamos leer: el archivo no se toca
        case unreadable
        /// `hooks` o uno de sus eventos no tiene la forma esperada: tampoco se toca
        case unexpectedShape
        /// El archivo existe y no se puede leer: no se toca (creerlo inexistente lo sobrescribiría)
        case cannotRead
        /// No se pudo guardar la copia de seguridad: no se escribe nada
        case cannotWrite
    }

    private static let argument = "claude-hook"
    private static let helperSuffix = "/Contents/Helpers/yb"
    static let timeout = 5

    /// Cada evento que se escucha y su filtro (`matcher`): las herramientas que preguntan, o ninguno. `PostToolUse` sin
    /// filtro porque es lo que dice que ya respondiste un permiso: la herramienta corre
    static let events: [(name: ClaudeHookEvent.Name, matcher: String?)] = [
        (.notification, nil),
        (.preToolUse, "AskUserQuestion|ExitPlanMode"),
        (.postToolUse, nil),
        (.userPromptSubmit, nil),
        (.stop, nil),
    ]

    /// El comando de los hooks, con la ruta del ayudante entre comillas simples, porque puede llevar espacios
    static func command(helperPath: String) -> String {
        "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "' " + argument
    }

    /// Un comando es de YabaiBar si es `<ruta>/Contents/Helpers/yb claude-hook`, con la ruta entre comillas o sin ellas. No
    /// vale cualquier `yb`: cualquier otro programa con ese nombre es de otro
    static func isOwn(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(" " + argument) else { return false }
        var executable = String(trimmed.dropLast(argument.count + 1)).trimmingCharacters(in: .whitespaces)
        if executable.count >= 2, let first = executable.first, first == "'" || first == "\"", executable.last == first {
            executable = String(executable.dropFirst().dropLast())
        }
        return executable.hasSuffix(helperSuffix)
    }

    // MARK: - Estado

    /// `data` es el contenido del archivo, o nil si no existe. Un archivo que no se lee cuenta como sin conectar
    static func status(of data: Data?, helperPath: String) -> Status {
        guard let data, let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return .notConnected }
        let expected = command(helperPath: helperPath)
        var found = 0
        var matching = 0
        for (name, _) in events {
            let commands = ownCommands(in: hooks[name.rawValue])
            if !commands.isEmpty { found += 1 }
            if commands.contains(expected) { matching += 1 }
        }
        if matching == events.count { return .connected }
        return found == 0 ? .notConnected : .outdated
    }

    // MARK: - Cambios

    /// El archivo con los hooks de YabaiBar puestos. Los de una conexión anterior se sustituyen, y lo demás no se toca.
    /// `data` es nil si el archivo no existe todavía
    static func connecting(_ data: Data?, helperPath: String) throws -> Data {
        var root = try data.map(parse) ?? [:]
        var hooks = try hooksTable(of: root)
        for (name, matcher) in events {
            var entries = try entries(of: hooks[name.rawValue])
            entries = removingOwn(from: entries)
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(helperPath: helperPath), "timeout": timeout]]]
            if let matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[name.rawValue] = entries
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// El archivo sin los hooks de YabaiBar. nil si no tenía ninguno: no hay nada que escribir
    static func disconnecting(_ data: Data) throws -> Data? {
        var root = try parse(data)
        guard root["hooks"] != nil else { return nil }
        var hooks = try hooksTable(of: root)
        var changed = false
        for name in Array(hooks.keys) {
            // Lo que no tiene la forma esperada no es nuestro: se deja como está
            guard let list = hooks[name] as? [[String: Any]], !ownCommands(in: list).isEmpty else { continue }
            let kept = removingOwn(from: list)
            // Un evento que solo tenía lo nuestro se quita entero, para no dejar `[]`
            hooks[name] = kept.isEmpty ? nil : kept
            changed = true
        }
        guard changed else { return nil }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    // MARK: - JSON

    private static func parse(_ data: Data) throws -> [String: Any] {
        // Un archivo vacío vale como `{}`
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return object
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { throw Failure.unreadable }
        return data + Data("\n".utf8)
    }

    private static func hooksTable(of root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let table = value as? [String: Any] else { throw Failure.unexpectedShape }
        return table
    }

    private static func entries(of value: Any?) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else { throw Failure.unexpectedShape }
        return list
    }

    private static func commands(in entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }

    private static func ownCommands(in value: Any?) -> [String] {
        ((value as? [[String: Any]]) ?? []).flatMap(commands(in:)).filter(isOwn(command:))
    }

    /// Quita de cada entrada los hooks nuestros, y la entrada si se queda sin ninguno
    private static func removingOwn(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
            let kept = inner.filter { !(($0["command"] as? String).map(isOwn(command:)) ?? false) }
            if kept.count == inner.count { return entry }
            if kept.isEmpty { return nil }
            var copy = entry
            copy["hooks"] = kept
            return copy
        }
    }
}

/// El archivo `~/.claude/settings.json`: leerlo, y conectar o desconectar con una copia de seguridad antes
struct ClaudeSettingsFile {
    var url: URL
    var helperPath: String

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    /// Donde se guarda el original antes del primer cambio. No se sobrescribe después
    var backupURL: URL { target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".bak-yabaibar") }

    // Si es un enlace (un repositorio de dotfiles), se escribe en lo que apunta: reemplazarlo lo convertiría en un archivo.
    // También si el enlace está colgante (el repositorio aún sin clonar): se crea el archivo al que apunta
    private var target: URL {
        var current = url
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = URL(filePath: destination, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
        }
        return current
    }

    /// nil si el archivo no existe. Si existe y no se puede leer (permisos, un directorio…) lanza: tratarlo como «no existe»
    /// escribiría un archivo nuevo encima de la configuración del usuario, y sin copia
    func read() throws -> Data? {
        do {
            return try Data(contentsOf: target)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw ClaudeHooksEditor.Failure.cannotRead
        }
    }

    func status() -> ClaudeHooksEditor.Status {
        ClaudeHooksEditor.status(of: (try? read()) ?? nil, helperPath: helperPath)
    }

    // Primero se calcula el archivo nuevo (si el JSON no vale, falla aquí y no se ha tocado nada, ni siquiera la copia), después
    // la copia y por último la escritura
    func connect() throws {
        let current = try read()
        let updated = try ClaudeHooksEditor.connecting(current, helperPath: helperPath)
        try backUp(current)
        try write(updated)
    }

    /// Devuelve si había algo que quitar
    @discardableResult
    func disconnect() throws -> Bool {
        guard let current = try read(), let updated = try ClaudeHooksEditor.disconnecting(current) else { return false }
        try backUp(current)
        try write(updated)
        return true
    }

    // La copia lleva los mismos permisos que el original: puede tener tokens en `env`
    private func backUp(_ data: Data?) throws {
        let manager = FileManager.default
        guard let data, !manager.fileExists(atPath: backupURL.path) else { return }
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] ?? 0o600
        guard manager.createFile(atPath: backupURL.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw ClaudeHooksEditor.Failure.cannotWrite
        }
    }

    private func write(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }
}
