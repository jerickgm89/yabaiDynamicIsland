import Foundation

// Geometría pura de las alas: el espacio activo va a la izquierda del notch y los inactivos a la derecha, con los
// indicadores al final (la música y mantener despierto). Las dos alas miden lo mismo (lo que necesite la más
// ancha), dentro de un mínimo y un máximo.
struct IslandLayout: Equatable {
    /// Lo que va al final del ala derecha, siempre en este orden: el anillo del Pomodoro, al borde
    enum StatusItem: Hashable, CaseIterable {
        case music, keepAwake, pomodoro

        var width: CGFloat {
            switch self {
            case .music: IslandLayout.musicIndicatorWidth
            // La taza es algo más ancha que alta
            case .keepAwake: 14
            case .pomodoro: IslandLayout.pomodoroRingSize
            }
        }
    }

    static let pomodoroRingSize: CGFloat = 12

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
    /// Lo más alto del contenido de las alas: el título y el subtítulo de un aviso
    static let closedContentHeight: CGFloat = 28

    /// Escala del contenido de las alas para que quepa en el alto del notch, con 1 pt libre arriba y abajo. Con los
    /// notch de 30 pt o más (los MacBook con su escala por defecto) es 1; con escalas de texto grande, menos
    static func contentScale(forHeight height: CGFloat) -> CGFloat {
        // Antes de medir la pantalla el alto es 0: sin esto, el contenido crecería desde 0 al aparecer
        guard height > 0 else { return 1 }
        return min(1, max(0, height - 2) / closedContentHeight)
    }

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

// Geometría pura de la isla abierta: debajo de la franja del notch, una tarjeta por espacio en una fila; debajo,
// la franja del Pomodoro si está en marcha y la de "Ahora suena" si suena algo. Nunca es más estrecha que la isla cerrada y, si hay muchos
// espacios, las tarjetas se estrechan.
struct IslandExpandedLayout: Equatable {
    static let cardWidth: CGFloat = 132
    static let cardHeight: CGFloat = 70
    static let cardSpacing: CGFloat = 8
    static let padding: CGFloat = 14
    /// Como en Atoll, la isla abierta deja al menos 30 pt libres a cada lado de la pantalla
    static let screenMargin: CGFloat = 30
    /// Separación entre la franja del notch y las tarjetas
    static let gapBelowNotch: CGFloat = 8
    static let maxIcons = 4
    static let iconSize: CGFloat = 22
    static let iconSpacing: CGFloat = 4
    /// Margen interior de cada tarjeta
    static let cardPadding: CGFloat = 10
    /// El "+n" de una tarjeta con más apps de las que caben ("+2" a 10 pt mide 13,1)
    static let overflowWidth: CGFloat = 14
    /// Lo que el "+n" puede comerse del margen derecho de la tarjeta: así caben 4 íconos y el "+n" en 132 pt
    static let overflowIntoPadding: CGFloat = 6
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

    /// Los botones de las esquinas, a la altura del notch: el Pomodoro a la izquierda y mantener despierto a la
    /// derecha
    static let cornerButtonSize: CGFloat = 26
    // La franja del Pomodoro: la fase y el progreso a la izquierda; la cuenta atrás y tres botones a la derecha
    static let pomodoroGap: CGFloat = 10
    static let pomodoroHeight: CGFloat = 44
    static let pomodoroControls: [Control] = [.pomodoroPlayPause, .pomodoroSkip, .pomodoroStop]

    /// Los botones de la isla abierta: los de la franja "Ahora suena", los del Pomodoro y los de las esquinas
    enum Control: Equatable {
        case artwork, previous, playPause, next, keepAwake
        case pomodoroToggle, pomodoroPlayPause, pomodoroSkip, pomodoroStop
    }

    let spaces: [SpaceSummary]
    let hasMedia: Bool
    let hasKeepAwake: Bool
    let hasPomodoro: Bool
    let hasPomodoroButton: Bool
    /// Ancho del cuerpo, sin las esquinas superiores cóncavas
    let bodyWidth: CGFloat
    let height: CGFloat
    let cardWidth: CGFloat

    /// Ancho de las franjas del Pomodoro y de "Ahora suena": todo el cuerpo menos los márgenes
    var mediaWidth: CGFloat { bodyWidth - 2 * Self.padding }

    /// Los íconos de una tarjeta con esas apps: hasta 4 con el ancho normal, menos si hay tantos espacios que las
    /// tarjetas se estrechan. Si no caben todas, se deja sitio al "+n"
    func iconsShown(appCount: Int) -> Int {
        let step = Self.iconSize + Self.iconSpacing
        let row = cardWidth - 2 * Self.cardPadding + Self.iconSpacing
        let all = min(Self.maxIcons, Int(row / step))
        if appCount <= all { return appCount }
        let beside = row + Self.overflowIntoPadding - Self.iconSpacing - Self.overflowWidth
        return min(Self.maxIcons, max(1, Int(beside / step)))
    }

    /// El cuerpo más ancho que cabe en una pantalla de ese ancho, con las esquinas superiores de la isla abierta
    static func maxBodyWidth(screenWidth: CGFloat, topRadius: CGFloat) -> CGFloat {
        screenWidth - 2 * screenMargin - 2 * topRadius
    }

    /// Los botones de las esquinas caben en la franja del notch, aunque sea baja
    static func cornerButtonSize(topHeight: CGFloat) -> CGFloat {
        min(cornerButtonSize, topHeight - 4)
    }

    /// `minBodyWidth` es lo que ocupan el notch y las alas en la franja de arriba. Con algún botón en las esquinas,
    /// el cuerpo deja sitio a cada lado para que no tapen las alas
    init(
        spaces: [SpaceSummary], minBodyWidth: CGFloat, maxBodyWidth: CGFloat, topHeight: CGFloat, hasMedia: Bool = false,
        hasKeepAwake: Bool = false, hasPomodoro: Bool = false, hasPomodoroButton: Bool = false
    ) {
        self.spaces = spaces
        self.hasMedia = hasMedia
        self.hasKeepAwake = hasKeepAwake
        self.hasPomodoro = hasPomodoro
        self.hasPomodoroButton = hasPomodoroButton
        let count = CGFloat(spaces.count)
        let gaps = max(0, count - 1) * Self.cardSpacing
        let natural = 2 * Self.padding + count * Self.cardWidth + gaps
        let corners = hasKeepAwake || hasPomodoroButton
        let minimum = minBodyWidth + (corners ? 2 * (Self.cornerButtonSize + Self.padding) : 0)
        bodyWidth = min(max(minimum, natural), max(minimum, maxBodyWidth))
        cardWidth = count > 0 ? min(Self.cardWidth, (bodyWidth - 2 * Self.padding - gaps) / count) : 0
        height = topHeight + Self.gapBelowNotch + Self.cardHeight
            + (hasPomodoro ? Self.pomodoroGap + Self.pomodoroHeight : 0)
            + (hasMedia ? Self.mediaGap + Self.mediaHeight : 0)
            + Self.padding
    }

    /// Dónde va el botón de mantener despierto, en coordenadas de la isla (origen arriba a la izquierda)
    func keepAwakeFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasKeepAwake else { return nil }
        let size = Self.cornerButtonSize(topHeight: topHeight)
        let x = (islandWidth + bodyWidth) / 2 - Self.padding - size
        return CGRect(x: x, y: (topHeight - size) / 2, width: size, height: size)
    }

    /// Dónde va el botón del Pomodoro, arriba a la izquierda, simétrico al de mantener despierto
    func pomodoroButtonFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasPomodoroButton else { return nil }
        let size = Self.cornerButtonSize(topHeight: topHeight)
        let x = (islandWidth - bodyWidth) / 2 + Self.padding
        return CGRect(x: x, y: (topHeight - size) / 2, width: size, height: size)
    }

    /// Dónde va la franja del Pomodoro, entre las tarjetas y la música
    func pomodoroStripFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasPomodoro else { return nil }
        let top = topHeight + Self.gapBelowNotch + Self.cardHeight + Self.pomodoroGap
        return CGRect(x: (islandWidth - mediaWidth) / 2, y: top, width: mediaWidth, height: Self.pomodoroHeight)
    }

    /// El botón bajo un punto de la isla: los de las esquinas (con un margen, para acertarlos fácil), los del
    /// Pomodoro o los de la franja "Ahora suena"
    func control(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Control? {
        if let frame = keepAwakeFrame(islandWidth: islandWidth, topHeight: topHeight), frame.insetBy(dx: -4, dy: -4).contains(point) {
            return .keepAwake
        }
        if let frame = pomodoroButtonFrame(islandWidth: islandWidth, topHeight: topHeight),
           frame.insetBy(dx: -4, dy: -4).contains(point) {
            return .pomodoroToggle
        }
        if let strip = pomodoroStripFrame(islandWidth: islandWidth, topHeight: topHeight), strip.contains(point) {
            return Self.control(atX: point.x - strip.minX, stripWidth: strip.width, controls: Self.pomodoroControls)
        }
        return mediaControl(at: point, islandWidth: islandWidth, topHeight: topHeight)
    }

    // Los tres botones de una franja, pegados a su borde derecho
    private static func control(atX x: CGFloat, stripWidth: CGFloat, controls: [Control]) -> Control? {
        let controlsX = x - (stripWidth - controlsWidth)
        guard controlsX >= 0 else { return nil }
        let index = Int(controlsX / (controlSize + controlSpacing))
        let offset = controlsX - CGFloat(index) * (controlSize + controlSpacing)
        return index < controls.count && offset < controlSize ? controls[index] : nil
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
        return Self.control(atX: x, stripWidth: mediaWidth, controls: Self.controls)
    }

    // La x del punto dentro de la franja, o nil si cae fuera
    private func stripX(of point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> CGFloat? {
        let top = topHeight + Self.gapBelowNotch + Self.cardHeight + (hasPomodoro ? Self.pomodoroGap + Self.pomodoroHeight : 0)
            + Self.mediaGap
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
