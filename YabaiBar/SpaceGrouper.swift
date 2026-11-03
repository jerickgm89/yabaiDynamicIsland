import Foundation

struct SpaceApp: Equatable, Sendable {
    let pid: Int32
    let name: String
}

struct SpaceSummary: Equatable, Sendable, Identifiable {
    let index: Int
    let isFocused: Bool
    let apps: [SpaceApp]
    var isFullscreen = false

    var id: Int { index }
}

// Lógica pura: de lo que devuelve yabai a lo que se dibuja, sin AppKit para poder testearla
enum SpaceGrouper {
    // yabai antepone marcas de dirección invisibles a algunos nombres (U+200E en WhatsApp)
    private static let invisibleCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))

    /// Espacios de la pantalla con foco, ordenados por índice, con sus apps visibles sin repetir.
    static func group(spaces: [YabaiSpace], windows: [YabaiWindow]) -> [SpaceSummary] {
        guard let display = (spaces.first(where: \.hasFocus) ?? spaces.first)?.display else { return [] }
        let visible = windows.filter { !$0.isMinimized && !$0.isHidden }

        return spaces
            .filter { $0.display == display }
            .sorted { $0.index < $1.index }
            .map { space in
                var seen = Set<Int32>()
                let apps = visible
                    .filter { $0.space == space.index && seen.insert($0.pid).inserted }
                    .map { SpaceApp(pid: $0.pid, name: $0.app.trimmingCharacters(in: invisibleCharacters)) }
                return SpaceSummary(
                    index: space.index, isFocused: space.hasFocus, apps: apps,
                    isFullscreen: space.isNativeFullscreen ?? false
                )
            }
    }
}
