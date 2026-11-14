import Foundation
import Testing
@testable import YabaiBar

// Añadir y quitar los hooks del settings.json de Claude Code sin tocar lo demás. Es lo único que escribe en la configuración
// de otra app, así que se prueba con archivos temporales y con los casos feos: JSON roto, `hooks` de otra forma, enlaces,
// hooks del usuario en los mismos eventos.
struct ClaudeHooksEditorTests {
    private let helper = "/Applications/YabaiBar.app/Contents/Helpers/yb"

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entries(_ root: [String: Any], _ event: String) throws -> [[String: Any]] {
        let hooks = try #require(root["hooks"] as? [String: Any])
        return try #require(hooks[event] as? [[String: Any]])
    }

    private func commands(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }

    private let userSettings = """
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(ls:*)"] },
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "~/bin/avisa-fin.sh" } ] } ],
            "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/revisa.sh" } ] } ],
            "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo hola" } ] } ]
          }
        }
        """

    // MARK: Reconocer lo propio

    @Test func ownCommandsAreOnlyTheOnesPointingToTheHelperInsideAnApp() {
        #expect(ClaudeHooksEditor.isOwn(command: ClaudeHooksEditor.command(helperPath: helper)))
        #expect(ClaudeHooksEditor.isOwn(command: ClaudeHooksEditor.command(helperPath: "/Users/ana/Mi App/YabaiBar.app/Contents/Helpers/yb")))
        // A mano, con o sin comillas
        #expect(ClaudeHooksEditor.isOwn(command: "/Applications/YabaiBar.app/Contents/Helpers/yb claude-hook"))
        #expect(ClaudeHooksEditor.isOwn(command: "\"/Applications/YabaiBar.app/Contents/Helpers/yb\" claude-hook"))
        // Cualquier otro programa, aunque se llame yb o haga lo mismo
        for other in [
            "yb claude-hook", "/usr/local/bin/yb claude-hook", "~/bin/avisa-fin.sh", "/x/Contents/Helpers/yb otra-cosa",
            "/x/Contents/Helpers/yb", "/x/Contents/Helpers/ybx claude-hook", "", "claude-hook",
        ] {
            #expect(!ClaudeHooksEditor.isOwn(command: other), "\(other)")
        }
    }

    @Test func aPathWithQuotesStaysOneArgument() {
        let tricky = "/Users/o'brien/YabaiBar.app/Contents/Helpers/yb"
        let command = ClaudeHooksEditor.command(helperPath: tricky)
        #expect(command == "'/Users/o'\\''brien/YabaiBar.app/Contents/Helpers/yb' claude-hook")
    }

    // MARK: Conectar

    @Test func connectingCreatesTheFiveHooksInAFreshFile() throws {
        let data = try ClaudeHooksEditor.connecting(nil, helperPath: helper)
        let root = try object(data)
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["Notification", "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"])
        let command = ClaudeHooksEditor.command(helperPath: helper)
        for (event, _) in hooks {
            let entry = try #require((hooks[event] as? [[String: Any]])?.first)
            #expect(commands(entry) == [command], "\(event)")
        }
        // Solo PreToolUse filtra, por las herramientas que preguntan
        #expect(try entries(root, "PreToolUse")[0]["matcher"] as? String == "AskUserQuestion|ExitPlanMode")
        #expect(try entries(root, "Stop")[0]["matcher"] == nil)
        #expect(ClaudeHooksEditor.status(of: data, helperPath: helper) == .connected)
    }

    @Test func connectingKeepsEverythingElse() throws {
        let data = try ClaudeHooksEditor.connecting(Data(userSettings.utf8), helperPath: helper)
        let root = try object(data)
        #expect(root["model"] as? String == "opus")
        #expect((root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)"])
        // Los hooks del usuario siguen donde estaban, y los nuestros van detrás
        let stop = try entries(root, "Stop")
        #expect(stop.count == 2 && commands(stop[0]) == ["~/bin/avisa-fin.sh"])
        #expect(ClaudeHooksEditor.isOwn(command: commands(stop[1])[0]))
        let pre = try entries(root, "PreToolUse")
        #expect(pre.count == 2 && pre[0]["matcher"] as? String == "Bash" && commands(pre[0]) == ["~/bin/revisa.sh"])
        let session = try entries(root, "SessionStart")
        #expect(session.count == 1 && commands(session[0]) == ["echo hola"])
    }

    // Conectar dos veces no los duplica; si la app se movió, sustituye los viejos
    @Test func connectingAgainReplacesInsteadOfDuplicating() throws {
        let once = try ClaudeHooksEditor.connecting(Data(userSettings.utf8), helperPath: helper)
        let twice = try ClaudeHooksEditor.connecting(once, helperPath: helper)
        #expect(try entries(object(twice), "Stop").count == 2)
        let moved = "/Users/ana/Apps/YabaiBar.app/Contents/Helpers/yb"
        let after = try ClaudeHooksEditor.connecting(twice, helperPath: moved)
        let stop = try entries(object(after), "Stop")
        #expect(stop.count == 2 && commands(stop[1]) == [ClaudeHooksEditor.command(helperPath: moved)])
        #expect(ClaudeHooksEditor.status(of: after, helperPath: moved) == .connected)
        #expect(ClaudeHooksEditor.status(of: after, helperPath: helper) == .outdated)
    }

    @Test func aFileWithAHookOfOursNextToTheUsersInTheSameEntryKeepsTheUsers() throws {
        let mixed = """
            { "hooks": { "Stop": [ { "hooks": [
              { "type": "command", "command": "~/bin/avisa-fin.sh" },
              { "type": "command", "command": "'\(helper)' claude-hook" } ] } ] } }
            """
        let removed = try #require(try ClaudeHooksEditor.disconnecting(Data(mixed.utf8)))
        let stop = try entries(object(removed), "Stop")
        #expect(stop.count == 1 && commands(stop[0]) == ["~/bin/avisa-fin.sh"])
    }

    // MARK: Quitar

    @Test func disconnectingRemovesOnlyOurEntries() throws {
        let connected = try ClaudeHooksEditor.connecting(Data(userSettings.utf8), helperPath: helper)
        let removed = try #require(try ClaudeHooksEditor.disconnecting(connected))
        let root = try object(removed)
        // Queda lo mismo que había
        #expect(try object(Data(userSettings.utf8)) as NSDictionary == root as NSDictionary)
        #expect(ClaudeHooksEditor.status(of: removed, helperPath: helper) == .notConnected)
    }

    @Test func disconnectingRemovesEmptyEventsAndHooks() throws {
        let connected = try ClaudeHooksEditor.connecting(Data(#"{"model":"opus"}"#.utf8), helperPath: helper)
        let removed = try #require(try ClaudeHooksEditor.disconnecting(connected))
        #expect(try object(removed) as NSDictionary == ["model": "opus"] as NSDictionary)
    }

    @Test func disconnectingWithNothingOfOursChangesNothing() throws {
        #expect(try ClaudeHooksEditor.disconnecting(Data(userSettings.utf8)) == nil)
        #expect(try ClaudeHooksEditor.disconnecting(Data(#"{"model":"opus"}"#.utf8)) == nil)
        #expect(try ClaudeHooksEditor.disconnecting(Data("{}".utf8)) == nil)
    }

    // MARK: Estado

    @Test func statusReadsTheFile() throws {
        #expect(ClaudeHooksEditor.status(of: nil, helperPath: helper) == .notConnected)
        #expect(ClaudeHooksEditor.status(of: Data("no es json".utf8), helperPath: helper) == .notConnected)
        #expect(ClaudeHooksEditor.status(of: Data(userSettings.utf8), helperPath: helper) == .notConnected)
        // Falta uno de los cinco: hay que volver a conectar
        let connected = try ClaudeHooksEditor.connecting(nil, helperPath: helper)
        var root = try object(connected)
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["Stop"] = nil
        root["hooks"] = hooks
        let partial = try JSONSerialization.data(withJSONObject: root)
        #expect(ClaudeHooksEditor.status(of: partial, helperPath: helper) == .outdated)
    }

    // MARK: Lo que no se puede tocar

    @Test func aBrokenFileIsNeverTouched() {
        for text in ["no es json", "[1,2]", "{\"hooks\": ", "// comentario\n{}"] {
            #expect(throws: ClaudeHooksEditor.Failure.unreadable, "\(text)") {
                try ClaudeHooksEditor.connecting(Data(text.utf8), helperPath: helper)
            }
            #expect(throws: ClaudeHooksEditor.Failure.unreadable, "\(text)") {
                try ClaudeHooksEditor.disconnecting(Data(text.utf8))
            }
        }
    }

    @Test func hooksOfAnotherShapeAreNeverTouched() {
        let shapes = [#"{"hooks": []}"#, #"{"hooks": "x"}"#, #"{"hooks": {"Stop": {"a": 1}}}"#, #"{"hooks": {"Stop": ["x"]}}"#]
        for text in shapes {
            #expect(throws: ClaudeHooksEditor.Failure.unexpectedShape, "\(text)") {
                try ClaudeHooksEditor.connecting(Data(text.utf8), helperPath: helper)
            }
        }
    }

    @Test func anEmptyFileCountsAsAnEmptyObject() throws {
        let data = try ClaudeHooksEditor.connecting(Data("  \n".utf8), helperPath: helper)
        #expect(ClaudeHooksEditor.status(of: data, helperPath: helper) == .connected)
    }

    // El resultado es un JSON bien formado, con los textos tal cual (sin escapar las barras)
    @Test func theOutputIsReadableJSON() throws {
        let data = try ClaudeHooksEditor.connecting(nil, helperPath: helper)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("/Applications/YabaiBar.app/Contents/Helpers/yb") && !text.contains("\\/"))
        #expect(text.hasSuffix("\n"))
    }
}

// El archivo de verdad, en una carpeta temporal
@MainActor
struct ClaudeSettingsFileTests {
    private let helper = "/Applications/YabaiBar.app/Contents/Helpers/yb"

    private func makeFile(_ content: String?, name: String = "settings.json") throws -> (file: ClaudeSettingsFile, root: URL) {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let url = root.appending(path: name)
        if let content { try content.write(to: url, atomically: true, encoding: .utf8) }
        return (ClaudeSettingsFile(url: url, helperPath: helper), root)
    }

    @Test func connectingBacksUpTheOriginalOnce() throws {
        let original = #"{"model":"opus"}"#
        let (file, _) = try makeFile(original)
        try file.connect()
        #expect(file.status() == .connected)
        #expect(try String(contentsOf: file.backupURL, encoding: .utf8) == original)
        // Conectar otra vez y quitar no sobrescriben la copia: sigue siendo el original
        try file.connect()
        try file.disconnect()
        #expect(try String(contentsOf: file.backupURL, encoding: .utf8) == original)
        #expect(file.status() == .notConnected)
    }

    @Test func connectingCreatesTheFileAndItsFolder() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let file = ClaudeSettingsFile(url: root.appending(path: "nuevo/settings.json"), helperPath: helper)
        try file.connect()
        #expect(file.status() == .connected)
        // No había nada que guardar
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    @Test func aBrokenFileIsLeftExactlyAsItWas() throws {
        let broken = "{ esto no es json"
        let (file, _) = try makeFile(broken)
        #expect(throws: ClaudeHooksEditor.Failure.unreadable) { try file.connect() }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == broken)
        // Ni siquiera la copia: si el usuario lo arregla y vuelve a conectar, la copia tiene que ser la del original bueno
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    // Un archivo que existe pero no se puede leer no es un archivo nuevo: escribir encima perdería la configuración
    @Test func anUnreadableFileIsNeverOverwritten() throws {
        let original = #"{"model":"opus","env":{"K":"v"}}"#
        let (file, _) = try makeFile(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path) }
        #expect(throws: ClaudeHooksEditor.Failure.cannotRead) { try file.connect() }
        #expect(throws: ClaudeHooksEditor.Failure.cannotRead) { try file.disconnect() }
        #expect(file.status() == .notConnected)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    // Un directorio donde se esperaba el archivo tampoco es «no existe»
    @Test func aDirectoryInPlaceOfTheFileIsNotAMissingFile() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let url = root.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = ClaudeSettingsFile(url: url, helperPath: helper)
        #expect(throws: ClaudeHooksEditor.Failure.cannotRead) { try file.connect() }
    }

    // La copia puede llevar tokens en `env`: no es más legible que el original
    @Test func theBackupKeepsThePermissionsOfTheOriginal() throws {
        let (file, _) = try makeFile(#"{"env":{"TOKEN":"secreto"}}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        try file.connect()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.backupURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    // Un enlace colgante (dotfiles sin clonar): se crea el archivo al que apunta y el enlace sigue siéndolo
    @Test func aDanglingSymlinkIsWrittenThrough() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let real = root.appending(path: "dotfiles/claude-settings.json")
        let link = root.appending(path: "settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = ClaudeSettingsFile(url: link, helperPath: helper)
        #expect(file.status() == .notConnected)
        try file.connect()
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(ClaudeHooksEditor.status(of: try Data(contentsOf: real), helperPath: helper) == .connected)
    }

    // Un settings.json que es un enlace (dotfiles): se escribe en lo que apunta y el enlace sigue siéndolo
    @Test func aSymlinkIsWrittenThroughNotReplaced() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let real = root.appending(path: "dotfiles-settings.json")
        try #"{"model":"opus"}"#.write(to: real, atomically: true, encoding: .utf8)
        let link = root.appending(path: "settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = ClaudeSettingsFile(url: link, helperPath: helper)
        try file.connect()
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(ClaudeHooksEditor.status(of: try Data(contentsOf: real), helperPath: helper) == .connected)
    }

    @Test func thePermissionsOfTheFileAreKept() throws {
        let (file, _) = try makeFile(#"{"model":"opus"}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        try file.connect()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func disconnectingWithNothingToRemoveWritesNothing() throws {
        let original = #"{"model":"opus"}"#
        let (file, _) = try makeFile(original)
        #expect(try file.disconnect() == false)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }
}

// «Conectar» y «Quitar» de Ajustes: preguntan antes y no hacen nada si el usuario dice que no
@MainActor
struct ClaudeConnectionTests {
    // Un ayudante que existe y se puede ejecutar, dentro de algo con la forma de una app
    private func makeHelper(in root: URL) throws -> String {
        let directory = root.appending(path: "YabaiBar.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appending(path: "yb")
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper.path
    }

    private func make(answer: Bool, content: String? = nil) throws -> (connection: ClaudeConnection, file: ClaudeSettingsFile) {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let url = root.appending(path: "settings.json")
        if let content { try content.write(to: url, atomically: true, encoding: .utf8) }
        let file = ClaudeSettingsFile(url: url, helperPath: try makeHelper(in: root))
        return (ClaudeConnection(file: file) { _, _, _ in answer }, file)
    }

    @Test func refusingChangesNothing() throws {
        let (connection, file) = try make(answer: false, content: #"{"model":"opus"}"#)
        #expect(connection.connect() == false)
        #expect(file.status() == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
        #expect(try String(contentsOf: file.url, encoding: .utf8) == #"{"model":"opus"}"#)
    }

    @Test func confirmingConnectsAndDisconnects() throws {
        let (connection, file) = try make(answer: true, content: #"{"model":"opus"}"#)
        #expect(connection.status == nil)
        #expect(connection.connect())
        #expect(connection.status == .connected && file.status() == .connected)
        #expect(connection.disconnect())
        #expect(connection.status == .notConnected)
    }

    // Sin el ayudante dentro de la app no se conecta nada: los hooks apuntarían a un programa que no existe
    @Test func withoutTheHelperNothingIsConnected() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let file = ClaudeSettingsFile(url: root.appending(path: "settings.json"), helperPath: "/no/existe/yb")
        let connection = ClaudeConnection(file: file) { _, _, _ in true }
        #expect(connection.connect() == false)
        #expect(connection.lastError != nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func aBrokenFileShowsAnErrorAndIsNotTouched() throws {
        let (connection, file) = try make(answer: true, content: "roto")
        #expect(connection.connect() == false)
        #expect(connection.lastError?.contains("no es un JSON válido") == true)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "roto")
    }
}
