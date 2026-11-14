import Foundation
@testable import YabaiBar

// Fixtures JSON reales de yabai, capturados con .claude/skills/yabai-api/scripts/capture-fixtures.sh
enum Fixture {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).json"))
    }

    /// Un fixture de texto, como la salida de `ps`
    static func text(_ name: String, extension fileExtension: String = "txt") throws -> String {
        try String(contentsOf: directory.appending(path: "\(name).\(fileExtension)"), encoding: .utf8)
    }

    static func path(_ name: String) -> String {
        directory.appending(path: "\(name).json").path(percentEncoded: false)
    }
}

// Ejecutable temporal que hace de yabai, para probar el cliente sin tocar el yabai real
enum FakeYabai {
    static func make(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "fake-yabai-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url.path(percentEncoded: false)
    }
}

/// Un `ClaudeSessions` que lee de una carpeta temporal y cuyo `settings.json` también lo es: nunca toca el `~/.claude` real
@MainActor
enum ClaudeTestSupport {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "claude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sessions(
        directory: URL? = nil, settingsFile: URL? = nil, now: @escaping () -> Date = { Date() },
        confirm: @escaping @MainActor (String, String, String) -> Bool = { _, _, _ in true }
    ) throws -> ClaudeSessions {
        let root = try temporaryDirectory()
        let connection = ClaudeConnection(
            file: ClaudeSettingsFile(
                url: settingsFile ?? root.appending(path: "settings.json"), helperPath: "/Applications/YabaiBar.app/Contents/Helpers/yb"
            ),
            confirm: confirm
        )
        return ClaudeSessions(connection: connection, directory: directory ?? root.appending(path: "sessions"), now: now)
    }
}
