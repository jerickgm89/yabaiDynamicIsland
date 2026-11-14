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
    /// La distribución del espacio: «bsp», «stack» o «float»
    var type: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, index, display, windows, type
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
    // Lo que usa el panel de yabai de la pestaña Escritorios. Opcional: tolera versiones sin el campo y los fixtures viejos. El título
    // puede llevar datos privados: no se loguea ni se guarda
    var title: String? = nil
    var hasFocus: Bool? = nil
    /// Sin referencia de accesibilidad no es una ventana de verdad (la propia isla, por ejemplo): yabai no puede enfocarla ni moverla
    var hasAxReference: Bool? = nil
    var isFloating: Bool? = nil
    var isSticky: Bool? = nil
    var hasParentZoom: Bool? = nil
    var hasFullscreenZoom: Bool? = nil
    var stackIndex: Int? = nil
    var subLayer: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, pid, app, space, title
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
        case hasFocus = "has-focus"
        case hasAxReference = "has-ax-reference"
        case isFloating = "is-floating"
        case isSticky = "is-sticky"
        case hasParentZoom = "has-parent-zoom"
        case hasFullscreenZoom = "has-fullscreen-zoom"
        case stackIndex = "stack-index"
        case subLayer = "sub-layer"
    }
}
