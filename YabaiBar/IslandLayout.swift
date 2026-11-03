import Foundation

// Geometría pura de las alas: el espacio activo va a la izquierda del notch y los inactivos a la derecha, con los
// indicadores al final (la música y mantener despierto). Las dos alas miden lo mismo (lo que necesite la más
// ancha), dentro de un mínimo y un máximo.
struct IslandLayout: Equatable {
    /// Lo que va al final del ala derecha, siempre en este orden
    enum StatusItem: Hashable, CaseIterable {
        case music, keepAwake

        var width: CGFloat {
            switch self {
            case .music: IslandLayout.musicIndicatorWidth
            case .keepAwake: 12
            }
        }
    }

    static let minWingWidth: CGFloat = 70
    static let maxWingWidth: CGFloat = 150
    /// Del borde exterior del ala a su contenido
    static let outerPadding: CGFloat = 12
    /// Del contenido al notch
    static let innerPadding: CGFloat = 8
    static let numberWidth: CGFloat = 20
    static let numberGap: CGFloat = 6
    static let iconSize: CGFloat = 20
    static let iconGap: CGFloat = 4
    static let maxIcons = 3
    static let overflowWidth: CGFloat = 22
    static let tokenWidth: CGFloat = 22
    static let minTokenWidth: CGFloat = 14
    static let musicIndicatorWidth: CGFloat = 14
    static let musicIndicatorGap: CGFloat = 6
    /// Durante el aviso de canción nueva las alas se abren al máximo, para que quepan la carátula y el título
    static let trackPeekWingWidth: CGFloat = maxWingWidth
    static let trackPeekArtworkSize: CGFloat = 24

    let active: SpaceSummary?
    let inactive: [SpaceSummary]
    let wingWidth: CGFloat
    /// Ancho de cada espacio inactivo; se estrecha si hay tantos que no caben en el ala máxima
    let tokenWidth: CGFloat
    /// El espacio activo es una app a pantalla completa: la isla se recoge al tamaño del notch para no estorbar
    let isCollapsed: Bool
    /// Los indicadores del final del ala derecha. Recogida a pantalla completa, ninguno
    let statusItems: [StatusItem]

    var showsMusicIndicator: Bool { statusItems.contains(.music) }

    var shownApps: ArraySlice<SpaceApp> { active?.apps.prefix(Self.maxIcons) ?? [] }
    var overflow: Int { max(0, (active?.apps.count ?? 0) - Self.maxIcons) }

    init(spaces: [SpaceSummary], statusItems: [StatusItem] = []) {
        active = spaces.first(where: \.isFocused)
        inactive = spaces.filter { !$0.isFocused }
        isCollapsed = active?.isFullscreen ?? false
        self.statusItems = isCollapsed ? [] : StatusItem.allCases.filter(statusItems.contains)

        let indicator = self.statusItems.reduce(0) { $0 + Self.musicIndicatorGap + $1.width }
        let left = Self.leftWidth(appCount: active?.apps.count ?? 0)
        let right = Self.innerPadding + CGFloat(inactive.count) * Self.tokenWidth + indicator + Self.outerPadding
        wingWidth = isCollapsed ? 0 : min(max(left, right, Self.minWingWidth), Self.maxWingWidth)

        let available = wingWidth - Self.innerPadding - Self.outerPadding - indicator
        tokenWidth = inactive.isEmpty
            ? Self.tokenWidth
            : max(Self.minTokenWidth, min(Self.tokenWidth, available / CGFloat(inactive.count)))
    }

    // Número + íconos visibles (+ "+n" si sobran) con sus márgenes
    static func leftWidth(appCount: Int) -> CGFloat {
        let shown = CGFloat(min(appCount, maxIcons))
        let icons = shown > 0 ? numberGap + shown * iconSize + (shown - 1) * iconGap : 0
        let overflow = appCount > maxIcons ? iconGap + overflowWidth : 0
        return outerPadding + numberWidth + icons + overflow + innerPadding
    }
}

// Geometría pura de la isla abierta: debajo de la franja del notch, una tarjeta por espacio en una fila y, si
// suena algo, la franja "Ahora suena" debajo. Nunca es más estrecha que la isla cerrada y, si hay muchos
// espacios, las tarjetas se estrechan.
struct IslandExpandedLayout: Equatable {
    static let cardWidth: CGFloat = 132
    static let cardHeight: CGFloat = 70
    static let cardSpacing: CGFloat = 8
    static let padding: CGFloat = 14
    /// Separación entre la franja del notch y las tarjetas
    static let gapBelowNotch: CGFloat = 8
    static let maxIcons = 4
    static let iconSize: CGFloat = 22
    // La franja "Ahora suena": carátula a la izquierda, título y progreso, y los tres botones a la derecha
    static let mediaGap: CGFloat = 10
    static let mediaHeight: CGFloat = 52
    static let artworkSize: CGFloat = 44
    static let controlSize: CGFloat = 30
    static let controlSpacing: CGFloat = 4
    static let controls: [Control] = [.previous, .playPause, .next]
    static var controlsWidth: CGFloat {
        CGFloat(controls.count) * controlSize + CGFloat(controls.count - 1) * controlSpacing
    }

    /// El botón de mantener despierto, arriba a la derecha, a la altura del notch
    static let keepAwakeSize: CGFloat = 26

    /// Los botones de la isla abierta: los de la franja "Ahora suena" y el de mantener despierto
    enum Control: Equatable {
        case artwork, previous, playPause, next, keepAwake
    }

    let spaces: [SpaceSummary]
    let hasMedia: Bool
    let hasKeepAwake: Bool
    /// Ancho del cuerpo, sin las esquinas superiores cóncavas
    let bodyWidth: CGFloat
    let height: CGFloat
    let cardWidth: CGFloat

    /// Ancho de la franja "Ahora suena": todo el cuerpo menos los márgenes
    var mediaWidth: CGFloat { bodyWidth - 2 * Self.padding }

    /// `minBodyWidth` es lo que ocupan el notch y las alas en la franja de arriba. Con el botón de mantener
    /// despierto, el cuerpo deja sitio a cada lado para que no tape las alas
    init(
        spaces: [SpaceSummary], minBodyWidth: CGFloat, maxBodyWidth: CGFloat, topHeight: CGFloat, hasMedia: Bool = false,
        hasKeepAwake: Bool = false
    ) {
        self.spaces = spaces
        self.hasMedia = hasMedia
        self.hasKeepAwake = hasKeepAwake
        let count = CGFloat(spaces.count)
        let gaps = max(0, count - 1) * Self.cardSpacing
        let natural = 2 * Self.padding + count * Self.cardWidth + gaps
        let minimum = minBodyWidth + (hasKeepAwake ? 2 * (Self.keepAwakeSize + Self.padding) : 0)
        bodyWidth = min(max(minimum, natural), max(minimum, maxBodyWidth))
        cardWidth = count > 0 ? min(Self.cardWidth, (bodyWidth - 2 * Self.padding - gaps) / count) : 0
        height = topHeight + Self.gapBelowNotch + Self.cardHeight + (hasMedia ? Self.mediaGap + Self.mediaHeight : 0)
            + Self.padding
    }

    /// Dónde va el botón de mantener despierto, en coordenadas de la isla (origen arriba a la izquierda)
    func keepAwakeFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasKeepAwake else { return nil }
        let x = (islandWidth + bodyWidth) / 2 - Self.padding - Self.keepAwakeSize
        return CGRect(x: x, y: (topHeight - Self.keepAwakeSize) / 2, width: Self.keepAwakeSize, height: Self.keepAwakeSize)
    }

    /// El botón bajo un punto de la isla: el de mantener despierto (con un margen, para acertarlo fácil) o uno de
    /// la franja "Ahora suena"
    func control(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Control? {
        if let frame = keepAwakeFrame(islandWidth: islandWidth, topHeight: topHeight), frame.insetBy(dx: -4, dy: -4).contains(point) {
            return .keepAwake
        }
        return mediaControl(at: point, islandWidth: islandWidth, topHeight: topHeight)
    }

    /// Si un punto de la isla (origen arriba a la izquierda) cae en la franja "Ahora suena"
    func mediaStripContains(_ point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Bool {
        stripX(of: point, islandWidth: islandWidth, topHeight: topHeight) != nil
    }

    /// El control de la franja "Ahora suena" bajo un punto de la isla. Cuenta toda la altura de la franja, para
    /// que los botones sean fáciles de acertar
    func mediaControl(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Control? {
        guard let x = stripX(of: point, islandWidth: islandWidth, topHeight: topHeight) else { return nil }
        if x < Self.artworkSize { return .artwork }
        let controlsX = x - (mediaWidth - Self.controlsWidth)
        guard controlsX >= 0 else { return nil }
        let index = Int(controlsX / (Self.controlSize + Self.controlSpacing))
        let offset = controlsX - CGFloat(index) * (Self.controlSize + Self.controlSpacing)
        return index < Self.controls.count && offset < Self.controlSize ? Self.controls[index] : nil
    }

    // La x del punto dentro de la franja, o nil si cae fuera
    private func stripX(of point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> CGFloat? {
        let top = topHeight + Self.gapBelowNotch + Self.cardHeight + Self.mediaGap
        guard hasMedia, point.y >= top, point.y < top + Self.mediaHeight else { return nil }
        let x = point.x - (islandWidth - mediaWidth) / 2
        return x >= 0 && x < mediaWidth ? x : nil
    }

    /// La tarjeta bajo un punto de la isla (origen arriba a la izquierda), o `nil` en los huecos y fuera de
    /// la fila. La fila de tarjetas va centrada en la isla, debajo de la franja del notch.
    func cardIndex(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Int? {
        let top = topHeight + Self.gapBelowNotch
        guard !spaces.isEmpty, point.y >= top, point.y < top + Self.cardHeight else { return nil }
        let rowWidth = CGFloat(spaces.count) * cardWidth + CGFloat(spaces.count - 1) * Self.cardSpacing
        let x = point.x - (islandWidth - rowWidth) / 2
        guard x >= 0, x < rowWidth else { return nil }
        let index = Int(x / (cardWidth + Self.cardSpacing))
        let offset = x - CGFloat(index) * (cardWidth + Self.cardSpacing)
        return offset < cardWidth ? index : nil
    }
}
