import Foundation

// Lo que devuelve `yabai -m query`; solo los campos que usa la app (verificados con yabai 7.1.25)

struct YabaiSpace: Decodable, Equatable, Sendable {
    let id: Int
    let index: Int
    let display: Int
    let windows: [Int]
    let hasFocus: Bool
    let isVisible: Bool
    /// Espacio de una app a pantalla completa nativa; opcional para tolerar versiones de yabai sin el campo
    var isNativeFullscreen: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, index, display, windows
        case hasFocus = "has-focus"
        case isVisible = "is-visible"
        case isNativeFullscreen = "is-native-fullscreen"
    }
}

struct YabaiWindow: Decodable, Equatable, Sendable {
    let id: Int
    let pid: Int32
    let app: String
    let space: Int
    let isMinimized: Bool
    let isHidden: Bool

    enum CodingKeys: String, CodingKey {
        case id, pid, app, space
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
    }
}
