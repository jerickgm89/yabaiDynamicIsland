import Foundation

// Fixtures JSON reales de yabai, capturados con .claude/skills/yabai-api/scripts/capture-fixtures.sh
enum Fixture {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).json"))
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
