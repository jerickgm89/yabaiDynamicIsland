import Foundation

// La chuleta de skhd (fase 45): los atajos de `~/.config/skhd/skhdrc` agrupados por sus comentarios, en solo lectura. Lógica pura: lee un
// texto, no el archivo. La app nunca escribe en el skhdrc.

struct SkhdBinding: Equatable, Sendable {
    /// Los atajos con los modificadores en símbolos: «⇧⌥ 1»
    var keys: String
    var command: String
}

struct SkhdGroup: Equatable, Identifiable, Sendable {
    var title: String
    var bindings: [SkhdBinding]

    var id: String { title }
}

enum SkhdCheatSheet {
    /// Un archivo de más de esto no es un skhdrc
    static let maxFileBytes = 200_000
    static let maxBindings = 300
    static let maxCommandLength = 90
    static let defaultTitle = "Atajos"

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config").appending(path: "skhd").appending(path: "skhdrc")
    }

    /// Lee el archivo si existe y es razonable; nil si no está
    static func read(at url: URL = defaultURL) -> [SkhdGroup]? {
        // Los dotfiles suelen ser enlaces: el tamaño es el del archivo al que apuntan, no el del enlace
        let real = url.resolvingSymlinksInPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: real.path)[.size] as? Int) ?? 0
        guard size > 0, size <= maxFileBytes, let data = try? Data(contentsOf: real) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    private static let modifierSymbols: [String: String] = [
        "shift": "⇧", "lshift": "⇧", "rshift": "⇧", "alt": "⌥", "lalt": "⌥", "ralt": "⌥", "cmd": "⌘", "lcmd": "⌘", "rcmd": "⌘",
        "ctrl": "⌃", "lctrl": "⌃", "rctrl": "⌃", "fn": "fn", "hyper": "⌘⌃⌥⇧", "meh": "⌃⌥⇧",
    ]

    /// Los atajos agrupados por el último comentario que los precede. Salta las líneas en blanco, los modos (`::`) y las directivas (`.load`,
    /// `.blacklist`…); une las líneas que acaban en `\`
    static func parse(_ text: String) -> [SkhdGroup] {
        var groups: [SkhdGroup] = []
        var title = defaultTitle
        var count = 0
        for line in logicalLines(text) {
            if count >= maxBindings { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("::") || trimmed.hasPrefix(".") { continue }
            if trimmed.hasPrefix("#") {
                // Un comentario sin « : » es un título; uno con « : » suele ser un atajo comentado
                let comment = trimmed.drop(while: { $0 == "#" || $0 == " " || $0 == "-" || $0 == "=" })
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -="))
                if !comment.isEmpty, !comment.contains(" : ") { title = String(comment.prefix(60)) }
                continue
            }
            guard let binding = binding(from: trimmed) else { continue }
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].bindings.append(binding)
            } else {
                groups.append(SkhdGroup(title: title, bindings: [binding]))
            }
            count += 1
        }
        return groups
    }

    // Las líneas con `\` al final siguen en la de abajo
    private static func logicalLines(_ text: String) -> [String] {
        var result: [String] = []
        var pending = ""
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasSuffix("\\") {
                pending += line.dropLast() + " "
            } else {
                result.append(pending + line)
                pending = ""
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    private static func binding(from line: String) -> SkhdBinding? {
        // «atajo : orden». Los atajos con modo son «modo < atajo : orden»; se ignora el modo
        guard let colon = line.firstIndex(of: ":") else { return nil }
        // Los espacios de las líneas unidas con `\` se reducen a uno: es para leer, no para ejecutar
        let command = line[line.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var keys = line[..<colon].trimmingCharacters(in: .whitespaces)
        if let angle = keys.lastIndex(of: "<") { keys = keys[keys.index(after: angle)...].trimmingCharacters(in: .whitespaces) }
        guard !keys.isEmpty, !command.isEmpty else { return nil }
        let shortened = command.count > maxCommandLength ? String(command.prefix(maxCommandLength - 1)) + "…" : command
        return SkhdBinding(keys: symbols(for: keys), command: shortened)
    }

    /// «shift + alt - 1» → «⇧⌥ 1»
    static func symbols(for keys: String) -> String {
        // Los modificadores van antes del último « - »; si no hay, es una tecla sola
        guard let dash = keys.range(of: " - ", options: .backwards) else { return keys }
        let modifiers = keys[..<dash.lowerBound].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let symbols = modifiers.map { modifierSymbols[$0] ?? $0 }.joined()
        return "\(symbols) \(keys[dash.upperBound...].trimmingCharacters(in: .whitespaces))"
    }
}
