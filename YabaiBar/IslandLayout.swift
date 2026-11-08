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

// Geometría pura de la isla abierta: en la franja del notch, los botones de las esquinas (el Pomodoro y la taza a la
// izquierda, el engranaje a la derecha); debajo, una tarjeta por espacio en una fila, y debajo, la fila de la música y
// el Pomodoro. Nunca es más estrecha que la isla cerrada y, si hay muchos
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
    // La fila de la música y el Pomodoro, debajo de las tarjetas. Si están los dos, la comparten separados por una
    // línea, la música a la izquierda; si solo hay uno, ocupa toda la fila. Así la isla no crece hacia abajo
    static let activityGap: CGFloat = 10
    static let activityHeight: CGFloat = 96
    /// La carátula y el anillo del Pomodoro
    static let coverSize: CGFloat = 86
    /// De la carátula o el anillo al texto
    static let coverGap: CGFloat = 14
    /// A cada lado de la línea que separa la música del Pomodoro
    static let dividerGap: CGFloat = 16
    /// Lo que se lleva la música cuando comparte la fila
    static let musicShare: CGFloat = 0.58
    static let controlSize: CGFloat = 30
    static let controlSpacing: CGFloat = 6
    /// Con la fila compartida, los botones van debajo del título, el álbum y el artista, alineados con el texto
    static let sharedControlsTop: CGFloat = 58
    /// Donde empieza el texto (título, álbum, artista; o fase, ronda, hoy) dentro de su parte
    static let sharedTextTop: CGFloat = 4
    static let musicTextTop: CGFloat = 10
    static let pomodoroTextTop: CGFloat = 18
    /// La barra de progreso de la música, debajo de los botones si comparte la fila
    static let sharedProgressTop: CGFloat = 86
    static let musicProgressTop: CGFloat = 66
    /// El símbolo de cada botón mide unos 18 pt en sus 30: el primero se corre esto para alinearse con el texto
    static let controlGlyphInset: CGFloat = 6
    /// Lo mínimo que mide cada parte de la fila compartida: caben el anillo, «Descanso largo» y los tres botones
    static let minSharedSection: CGFloat = 220
    /// Lo mínimo que mide la fila con una sola parte: la carátula, algo de texto y los botones a la derecha
    static let minSingleRow: CGFloat = 330
    static let controls: [Control] = [.previous, .playPause, .next]

    /// Los botones de las esquinas, a la altura del notch: el Pomodoro y la taza a la izquierda, y el engranaje de
    /// los ajustes a la derecha
    static let cornerButtonSize: CGFloat = 26
    static let cornerButtonSpacing: CGFloat = 4
    static let pomodoroControls: [Control] = [.pomodoroPlayPause, .pomodoroSkip, .pomodoroStop]

    /// Los botones de la isla abierta: los de la música, los del Pomodoro y los de las esquinas
    enum Control: Hashable {
        case artwork, previous, playPause, next, keepAwake, settings
        case pomodoroToggle, pomodoroPlayPause, pomodoroSkip, pomodoroStop
    }

    let spaces: [SpaceSummary]
    let hasMedia: Bool
    let hasKeepAwake: Bool
    let hasPomodoro: Bool
    let hasPomodoroButton: Bool
    let hasSettingsButton: Bool
    /// Ancho del cuerpo, sin las esquinas superiores cóncavas
    let bodyWidth: CGFloat
    let height: CGFloat
    let cardWidth: CGFloat

    /// Ancho de la fila de la música y el Pomodoro: todo el cuerpo menos los márgenes
    var mediaWidth: CGFloat { bodyWidth - 2 * Self.padding }
    var hasActivity: Bool { hasMedia || hasPomodoro }
    /// La música y el Pomodoro comparten la fila
    var sharesActivityRow: Bool { hasMedia && hasPomodoro }

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
        hasKeepAwake: Bool = false, hasPomodoro: Bool = false, hasPomodoroButton: Bool = false,
        hasSettingsButton: Bool = false
    ) {
        self.spaces = spaces
        self.hasMedia = hasMedia
        self.hasKeepAwake = hasKeepAwake
        self.hasPomodoro = hasPomodoro
        self.hasPomodoroButton = hasPomodoroButton
        self.hasSettingsButton = hasSettingsButton
        let count = CGFloat(spaces.count)
        let gaps = max(0, count - 1) * Self.cardSpacing
        let natural = 2 * Self.padding + count * Self.cardWidth + gaps
        // Las alas van centradas en el notch: cada lado deja sitio a los botones del lado que más tenga
        let left = Self.cornerWidth(buttons: (hasPomodoroButton ? 1 : 0) + (hasKeepAwake ? 1 : 0))
        let right = Self.cornerWidth(buttons: hasSettingsButton ? 1 : 0)
        let corner = max(left, right)
        var minimum = minBodyWidth + (corner > 0 ? 2 * (corner + Self.padding) : 0)
        // La fila de la música y el Pomodoro necesita su sitio aunque haya pocos escritorios
        if hasMedia && hasPomodoro {
            minimum = max(minimum, 2 * Self.padding + 2 * Self.minSharedSection + 2 * Self.dividerGap)
        } else if hasMedia || hasPomodoro {
            minimum = max(minimum, 2 * Self.padding + Self.minSingleRow)
        }
        bodyWidth = min(max(minimum, natural), max(minimum, maxBodyWidth))
        cardWidth = count > 0 ? min(Self.cardWidth, (bodyWidth - 2 * Self.padding - gaps) / count) : 0
        height = topHeight + Self.gapBelowNotch + Self.cardHeight
            + (hasMedia || hasPomodoro ? Self.activityGap + Self.activityHeight : 0)
            + Self.padding
    }

    // Lo que ocupan varios botones de esquina seguidos
    private static func cornerWidth(buttons: Int) -> CGFloat {
        buttons > 0 ? CGFloat(buttons) * cornerButtonSize + CGFloat(buttons - 1) * cornerButtonSpacing : 0
    }

    // El botón número `index` de la esquina izquierda, en coordenadas de la isla (origen arriba a la izquierda)
    private func leftCornerFrame(_ index: Int, islandWidth: CGFloat, topHeight: CGFloat) -> CGRect {
        let size = Self.cornerButtonSize(topHeight: topHeight)
        let x = (islandWidth - bodyWidth) / 2 + Self.padding + CGFloat(index) * (size + Self.cornerButtonSpacing)
        return CGRect(x: x, y: (topHeight - size) / 2, width: size, height: size)
    }

    /// El botón del Pomodoro, el primero de la esquina izquierda
    func pomodoroButtonFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasPomodoroButton else { return nil }
        return leftCornerFrame(0, islandWidth: islandWidth, topHeight: topHeight)
    }

    /// La taza de mantener despierto, a la derecha del Pomodoro (o la primera, sin él)
    func keepAwakeFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasKeepAwake else { return nil }
        return leftCornerFrame(hasPomodoroButton ? 1 : 0, islandWidth: islandWidth, topHeight: topHeight)
    }

    /// El engranaje de los ajustes, en la esquina derecha
    func settingsButtonFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard hasSettingsButton else { return nil }
        let size = Self.cornerButtonSize(topHeight: topHeight)
        let x = (islandWidth + bodyWidth) / 2 - Self.padding - size
        return CGRect(x: x, y: (topHeight - size) / 2, width: size, height: size)
    }

    // MARK: - La fila de la música y el Pomodoro

    /// Dónde empieza la fila, en coordenadas de la isla (origen arriba a la izquierda)
    func activityOrigin(islandWidth: CGFloat, topHeight: CGFloat) -> CGPoint {
        CGPoint(x: (islandWidth - mediaWidth) / 2, y: topHeight + Self.gapBelowNotch + Self.cardHeight + Self.activityGap)
    }

    /// La parte de la música, en coordenadas de la fila: toda la fila si no hay Pomodoro
    var musicSection: CGRect? {
        guard hasMedia else { return nil }
        guard hasPomodoro else { return CGRect(x: 0, y: 0, width: mediaWidth, height: Self.activityHeight) }
        // El reparto, sin dejar a ninguna de las dos por debajo de su mínimo
        let shared = mediaWidth - 2 * Self.dividerGap
        let width = min(max((shared * Self.musicShare).rounded(), Self.minSharedSection), shared - Self.minSharedSection)
        return CGRect(x: 0, y: 0, width: width, height: Self.activityHeight)
    }

    /// La parte del Pomodoro, en coordenadas de la fila: toda la fila si no hay música
    var pomodoroSection: CGRect? {
        guard hasPomodoro else { return nil }
        let x = musicSection.map { $0.maxX + 2 * Self.dividerGap } ?? 0
        return CGRect(x: x, y: 0, width: mediaWidth - x, height: Self.activityHeight)
    }

    /// La x de la línea que separa las dos partes, en coordenadas de la fila
    var dividerX: CGFloat? {
        guard sharesActivityRow, let music = musicSection else { return nil }
        return music.maxX + Self.dividerGap
    }

    /// La carátula o el anillo de una parte, a su izquierda y centrado en alto
    static func coverFrame(in section: CGRect) -> CGRect {
        CGRect(x: section.minX, y: section.minY + (section.height - coverSize) / 2, width: coverSize, height: coverSize)
    }

    /// Donde empieza el texto de una parte, a la derecha de la carátula o el anillo
    static func textX(in section: CGRect) -> CGFloat {
        section.minX + coverSize + coverGap
    }

    /// Los botones de una parte. Con la fila compartida van debajo del texto (el primero, alineado con él); si
    /// no, a la derecha y centrados en alto
    func controlFrames(_ controls: [Control], in section: CGRect) -> [(control: Control, frame: CGRect)] {
        let step = Self.controlSize + Self.controlSpacing
        let width = CGFloat(controls.count) * step - Self.controlSpacing
        let origin = sharesActivityRow
            ? CGPoint(x: Self.textX(in: section) - Self.controlGlyphInset, y: section.minY + Self.sharedControlsTop)
            : CGPoint(x: section.maxX - width, y: section.midY - Self.controlSize / 2)
        return controls.enumerated().map { index, control in
            (control, CGRect(x: origin.x + CGFloat(index) * step, y: origin.y, width: Self.controlSize, height: Self.controlSize))
        }
    }

    /// El botón bajo un punto de la isla: los de las esquinas (con un margen, para acertarlos fácil), la carátula
    /// y los de la música, o los del Pomodoro
    func control(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Control? {
        if let frame = keepAwakeFrame(islandWidth: islandWidth, topHeight: topHeight), frame.insetBy(dx: -2, dy: -4).contains(point) {
            return .keepAwake
        }
        if let frame = settingsButtonFrame(islandWidth: islandWidth, topHeight: topHeight),
           frame.insetBy(dx: -4, dy: -4).contains(point) {
            return .settings
        }
        if let frame = pomodoroButtonFrame(islandWidth: islandWidth, topHeight: topHeight),
           frame.insetBy(dx: -2, dy: -4).contains(point) {
            return .pomodoroToggle
        }
        let origin = activityOrigin(islandWidth: islandWidth, topHeight: topHeight)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if let music = musicSection {
            if Self.coverFrame(in: music).contains(local) { return .artwork }
            if let hit = controlFrames(Self.controls, in: music).first(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(local) }) {
                return hit.control
            }
        }
        if let pomodoro = pomodoroSection,
           let hit = controlFrames(Self.pomodoroControls, in: pomodoro).first(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(local) }) {
            return hit.control
        }
        return nil
    }

    /// Si un punto de la isla cae en la parte de la música (para el gesto de dos dedos de lado)
    func musicContains(_ point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat) -> Bool {
        guard let music = musicSection else { return false }
        let origin = activityOrigin(islandWidth: islandWidth, topHeight: topHeight)
        return music.contains(CGPoint(x: point.x - origin.x, y: point.y - origin.y))
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
