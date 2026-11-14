import CoreGraphics
import Foundation

// Lógica pura del panel de yabai de la pestaña Escritorios (fase 45): las ventanas del escritorio activo, qué hace cada botón, dónde está
// cada cosa para dibujarla y resolver los clics, y cómo se cuenta un fallo de yabai. Nada de aquí ejecuta yabai ni toca AppKit.
// Los títulos de las ventanas pueden llevar datos privados: no se loguean y el snapshot de DEBUG no los dibuja.

// MARK: - Las ventanas del escritorio activo

struct DesktopWindow: Equatable, Identifiable, Sendable {
    var id: Int
    var pid: Int32
    var app: String
    /// El título, limpio y recortado; si no tiene, el nombre de la app
    var title: String
    var isFocused: Bool
    var isFloating: Bool
    var isSticky: Bool
    var hasParentZoom: Bool
    var hasFullscreenZoom: Bool
    var stackIndex: Int?
    var subLayer: String?

    /// Siempre encima: lo que dice yabai de su nivel de apilado
    var isAbove: Bool { subLayer == "above" }
}

enum DesktopWindows {
    static let maxTitleLength = 80
    private static let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))

    /// Un título para enseñar: sin caracteres de control ni saltos de línea, sin espacios de sobra y recortado
    static func cleanTitle(_ title: String?, fallback: String) -> String {
        let scalars = (title ?? "").unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        var text = String(scalars).trimmingCharacters(in: invisible)
        if text.count > maxTitleLength { text = String(text.prefix(maxTitleLength - 1)) + "…" }
        return text.isEmpty ? fallback : text
    }

    /// El escritorio con foco de la pantalla con foco, su distribución y sus ventanas visibles: las apiladas por su posición en la pila
    /// y el resto por su identificador (que no cambia). Sin escritorio con foco, nada
    static func make(
        spaces: [YabaiSpace], windows: [YabaiWindow], excludingPID ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> (spaceIndex: Int, layout: YabaiLayout?, windows: [DesktopWindow])? {
        guard let space = spaces.first(where: \.hasFocus) else { return nil }
        let layout = space.type.flatMap(YabaiLayout.init(rawValue:))
        // Sin la propia isla ni lo que no es una ventana de verdad (sin referencia de accesibilidad): ni se puede enfocar ni mover
        let usable = windows.filter {
            $0.space == space.index && !$0.isMinimized && !$0.isHidden && $0.pid != ownPID && $0.hasAxReference != false
        }
        let visible = usable.map { window -> DesktopWindow in
            let app = window.app.trimmingCharacters(in: invisible)
            return DesktopWindow(
                id: window.id, pid: window.pid, app: app, title: cleanTitle(window.title, fallback: app),
                isFocused: window.hasFocus ?? false, isFloating: window.isFloating ?? false, isSticky: window.isSticky ?? false,
                hasParentZoom: window.hasParentZoom ?? false, hasFullscreenZoom: window.hasFullscreenZoom ?? false,
                stackIndex: window.stackIndex, subLayer: window.subLayer
            )
        }
        let ordered = visible.sorted {
            if layout == .stack, let left = $0.stackIndex, let right = $1.stackIndex, left != right { return left < right }
            return $0.id < $1.id
        }
        return (space.index, layout, ordered)
    }
}

struct DesktopControlMessage: Equatable, Sendable {
    var text: String
    var isError: Bool
}

/// Lo que dibuja el panel
struct DesktopControlSnapshot: Equatable, Sendable {
    /// El escritorio activo; nil mientras no se ha leído o yabai no responde
    var spaceIndex: Int?
    var layout: YabaiLayout?
    var windows: [DesktopWindow] = []
    /// Las apps que siempre flotan (la lista de Ajustes), para encender el botón de la ventana enfocada
    var floatApps: [String] = []
    /// Los escritorios cuya distribución se recuerda («Recordar en el N» encendido)
    var rememberedLayouts: [Int: YabaiLayout] = [:]
    /// Los escritorios en modo presentación (sin márgenes ni huecos) por lo que ha hecho la app: yabai no dice si está activo
    var presentationSpaces: Set<Int> = []
    /// «yabai-v7.1.25»
    var yabaiVersion: String?
    /// La scripting addition parece cargada: sin ella, lo que la necesita se atenúa
    var scriptingAddition = false
    var message: DesktopControlMessage?

    var focused: DesktopWindow? { windows.first(where: \.isFocused) }
}

// MARK: - Los controles

enum DesktopControl: Hashable, Sendable {
    /// Una ventana del escritorio activo, por su identificador de yabai: un clic la enfoca y arrastrarla a una tarjeta la mueve
    case window(Int)
    /// La distribución del escritorio activo
    case layout(YabaiLayout)
    /// «Recordar en el N»: la app vuelve a poner la distribución de este escritorio cuando yabai se reinicia
    case rememberLayout
    case balance, rotate
    case mirror(YabaiAxis)
    /// Quita los márgenes y los huecos del escritorio, o los devuelve
    case presentation
    // La ventana enfocada
    case toggleFloat, split, makeMain
    /// Un botón que pasa del zoom al padre al zoom a todo el escritorio y lo quita
    case zoom
    /// Esta app, siempre flotante: una regla de yabai que la app recuerda
    case floatApp
    case sticky, above
    // Los escritorios: la tarjeta «+» y los botoncitos de la cabecera de «Escritorio»
    case newSpace, removeSpace
    case moveSpace(forward: Bool)
    /// Pasar por las ventanas de la pila
    case stack(forward: Bool)
    /// «Atajos de skhd»: abre la chuleta (Ajustes › Escritorios). No es una orden de yabai
    case skhd

    /// Lo que pide a yabai. nil si no se puede (sin ventana enfocada, sin escritorio…) o si no es una orden (recordar, skhd)
    func action(snapshot: DesktopControlSnapshot) -> YabaiAction? {
        switch self {
        case .window(let id): return .focusWindow(id)
        case .layout(let layout): return .setLayout(layout)
        case .rememberLayout, .skhd: return nil
        case .balance: return .balance
        case .rotate: return .rotate
        case .mirror(let axis): return .mirror(axis)
        case .presentation: return .togglePresentation
        case .toggleFloat: return snapshot.focused == nil ? nil : .toggleFloat
        case .split: return snapshot.focused == nil ? nil : .toggleSplit
        case .makeMain: return snapshot.focused == nil ? nil : .swapWithLargest
        case .zoom:
            guard let focused = snapshot.focused else { return nil }
            // Sin zoom → al padre → a todo el escritorio → sin zoom
            if focused.hasFullscreenZoom { return .toggleZoomFullscreen }
            return focused.hasParentZoom ? .switchZoomToFullscreen : .toggleZoomParent
        case .floatApp:
            guard let app = snapshot.focused.flatMap({ YabaiRules.clean($0.app) }) else { return nil }
            return snapshot.floatApps.contains(app) ? .removeFloatRule(app: app) : .addFloatRule(app: app)
        case .sticky: return snapshot.focused == nil ? nil : .toggleSticky
        case .above:
            guard let focused = snapshot.focused else { return nil }
            return .setSubLayer(focused.isAbove ? .auto : .above)
        case .newSpace: return .createSpace
        case .removeSpace: return snapshot.spaceIndex.map { .destroySpace($0) }
        case .moveSpace(let forward): return .moveSpace(forward: forward)
        case .stack(let forward): return .stackStep(forward: forward)
        }
    }

    /// El símbolo de los botones que no llevan texto
    var symbol: String? {
        switch self {
        case .layout(let layout):
            switch layout {
            case .bsp: "square.grid.2x2"
            case .stack: "square.stack"
            case .float: "macwindow.on.rectangle"
            }
        case .balance: "equal.square"
        case .rotate: "rotate.right"
        case .mirror(let axis): axis == .x ? "arrow.left.and.right.righttriangle.left.righttriangle.right" : "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .sticky: "pin"
        case .above: "square.3.layers.3d.top.filled"
        case .newSpace: "plus"
        case .removeSpace: "minus"
        case .moveSpace(let forward): forward ? "chevron.right" : "chevron.left"
        case .stack(let forward): forward ? "chevron.right" : "chevron.left"
        default: nil
        }
    }

    /// El texto de los botones que lo llevan, como en el diseño
    var label: String? {
        switch self {
        case .layout(let layout): layout == .bsp ? "BSP" : layout.title
        case .toggleFloat: "Flotante"
        case .zoom: "Zoom"
        case .split: "Dividir"
        case .makeMain: "Principal"
        case .floatApp: "Siempre flotante"
        case .presentation: "Presentación"
        case .rememberLayout: "Recordar"
        case .skhd: "Atajos de skhd"
        default: nil
        }
    }

    /// Lo que dice la cabecera de su sección al pasar el puntero (los botones sin texto no tienen otro nombre)
    func title(snapshot: DesktopControlSnapshot = DesktopControlSnapshot()) -> String {
        switch self {
        case .window(let id):
            guard let window = snapshot.windows.first(where: { $0.id == id }) else { return "Enfocar la ventana" }
            return "\(window.app) — \(window.title)"
        case .layout(let layout): return "Distribución: \(layout.title.lowercased())"
        case .rememberLayout: return "Recordar la distribución de este escritorio"
        case .balance: return "Equilibrar"
        case .rotate: return "Rotar 90 grados"
        case .mirror(let axis): return axis == .x ? "Espejo horizontal" : "Espejo vertical"
        case .presentation: return "Presentación: sin márgenes ni huecos"
        case .toggleFloat: return "Flotante o en mosaico"
        case .split: return "Cambiar la división"
        case .makeMain: return "Hacerla la ventana principal"
        case .zoom:
            if snapshot.focused?.hasFullscreenZoom == true { return "Quitar el zoom" }
            return snapshot.focused?.hasParentZoom == true ? "Zoom a todo el escritorio" : "Zoom al padre"
        case .floatApp: return "Esta app, siempre flotante"
        case .sticky: return "En todos los escritorios"
        case .above: return "Siempre encima"
        case .newSpace: return "Crear un escritorio"
        case .removeSpace: return "Quitar este escritorio"
        case .moveSpace(let forward): return forward ? "Mover el escritorio a la derecha" : "Mover el escritorio a la izquierda"
        case .stack(let forward): return forward ? "Ventana siguiente de la pila" : "Ventana anterior de la pila"
        case .skhd: return "Abrir la chuleta de atajos de skhd"
        }
    }

    /// Lo que necesita de la scripting addition (para atenuarlo si no parece cargada)
    var scriptingAddition: ScriptingAdditionNeed {
        switch self {
        case .sticky, .above, .newSpace, .removeSpace, .moveSpace: .required
        default: .none
        }
    }

    /// Si el botón está encendido con lo que se sabe ahora (la distribución actual, una ventana flotante…)
    func isOn(snapshot: DesktopControlSnapshot) -> Bool {
        let focused = snapshot.focused
        switch self {
        case .layout(let layout): return snapshot.layout == layout
        case .rememberLayout: return snapshot.spaceIndex.map { snapshot.rememberedLayouts[$0] != nil } ?? false
        case .presentation: return snapshot.spaceIndex.map { snapshot.presentationSpaces.contains($0) } ?? false
        case .floatApp: return focused.flatMap { YabaiRules.clean($0.app) }.map(snapshot.floatApps.contains) ?? false
        case .toggleFloat: return focused?.isFloating ?? false
        case .zoom: return (focused?.hasParentZoom ?? false) || (focused?.hasFullscreenZoom ?? false)
        case .sticky: return focused?.isSticky ?? false
        case .above: return focused?.isAbove ?? false
        case .window(let id): return focused?.id == id
        default: return false
        }
    }

    /// Los botones que solo valen con la ventana enfocada, para atenuarlos sin ella
    var needsFocusedWindow: Bool {
        switch self {
        case .toggleFloat, .zoom, .split, .makeMain, .floatApp, .sticky, .above: true
        default: false
        }
    }

    /// El botón de la pila solo sirve con el escritorio en pila: en otra distribución, se ve atenuado
    func isDimmed(snapshot: DesktopControlSnapshot) -> Bool {
        (scriptingAddition == .required && !snapshot.scriptingAddition)
            || (needsFocusedWindow && snapshot.focused == nil)
            || (isStack && snapshot.layout != .stack)
    }

    private var isStack: Bool {
        if case .stack = self { true } else { false }
    }
}

// MARK: - Dónde está cada cosa

/// Los marcos del panel, en coordenadas del panel (origen arriba a la izquierda), siguiendo el diseño: cinco secciones en tarjetas
/// (las ventanas y la distribución arriba; la ventana enfocada, el escritorio y yabai debajo)
struct DesktopPanelFrames {
    struct Button: Equatable {
        var control: DesktopControl
        var frame: CGRect
    }

    var windowsSection = CGRect.zero, layoutSection = CGRect.zero, focusedSection = CGRect.zero
    var spaceSection = CGRect.zero, statusSection = CGRect.zero
    /// Las ventanas dibujadas, en orden, y el «+n» si no caben todas
    var chips: [CGRect] = []
    var overflow: CGRect?
    /// En la cabecera de «Ventanas»: la pila
    var stack: [Button] = []
    var remember = Button(control: .rememberLayout, frame: .zero)
    var segmentedTrack = CGRect.zero
    var segments: [Button] = []
    var layoutIcons: [Button] = []
    var focusedText: [Button] = []
    var focusedMini: [Button] = []
    var presentation = Button(control: .presentation, frame: .zero)
    var spaceMini: [Button] = []
    var skhd = Button(control: .skhd, frame: .zero)

    /// Todo lo que se pulsa, menos las ventanas
    var buttons: [Button] {
        stack + [remember] + segments + layoutIcons + focusedText + focusedMini + [presentation] + spaceMini + [skhd]
    }
}

enum DesktopPanelLayout {
    /// Entre las tarjetas y el panel, y entre sus dos filas de secciones
    static let gap: CGFloat = 10
    static let rowGap: CGFloat = 10
    static let primaryHeight: CGFloat = 82
    static let secondaryHeight: CGFloat = 62
    static let height: CGFloat = primaryHeight + rowGap + secondaryHeight
    /// Lo mínimo que mide para que quepan las secciones del diseño (768 pt de cuerpo con sus márgenes)
    static let minWidth: CGFloat = 740
    static let spacing: CGFloat = 10

    static let padding: CGFloat = 10
    static let secondaryInsetY: CGFloat = 8
    static let headerHeight: CGFloat = 12
    static let chipHeight: CGFloat = 34
    static let chipSpacing: CGFloat = 6
    static let chipMinWidth: CGFloat = 96
    static let overflowWidth: CGFloat = 34
    static let maxChips = 8
    static let layoutSectionWidth: CGFloat = 340
    static let spaceSectionWidth: CGFloat = 150
    static let statusSectionWidth: CGFloat = 180
    static let segmentedHeight: CGFloat = 34
    static let segmentedInset: CGFloat = 2
    static let iconButtonSize = CGSize(width: 30, height: 34)
    static let iconSpacing: CGFloat = 6
    static let textButtonHeight: CGFloat = 26
    static let textButtonSpacing: CGFloat = 5
    static let miniSize = CGSize(width: 16, height: 16)
    static let miniSpacing: CGFloat = 2
    static let pillSize = CGSize(width: 100, height: 16)
    static let switchSize = CGSize(width: 30, height: 18)
    static let skhdWidth: CGFloat = 104

    /// Lo que mide cada botón de texto de «Ventana enfocada» con su texto y su margen (como en el diseño); se encogen juntos si no caben
    private static let focusedWidths: [CGFloat] = [58, 46, 54, 66, 104]
    private static let focusedControls: [DesktopControl] = [.toggleFloat, .zoom, .split, .makeMain, .floatApp]

    /// Las cinco secciones. La de la distribución mide 340 (menos si el panel es más estrecho de lo normal) y las de «Escritorio» y «yabai»
    /// 150 y 180; lo que sobra es de las ventanas y de la ventana enfocada
    static func sections(width: CGFloat) -> [CGRect] {
        let layoutWidth = min(layoutSectionWidth, max(250, (width - spacing) * 0.5))
        let windowsWidth = max(0, width - spacing - layoutWidth)
        let secondaryY = primaryHeight + rowGap
        let statusWidth = min(statusSectionWidth, max(120, width * 0.25))
        let spaceWidth = min(spaceSectionWidth, max(110, width * 0.21))
        let focusedWidth = max(0, width - 2 * spacing - spaceWidth - statusWidth)
        return [
            CGRect(x: 0, y: 0, width: windowsWidth, height: primaryHeight),
            CGRect(x: windowsWidth + spacing, y: 0, width: layoutWidth, height: primaryHeight),
            CGRect(x: 0, y: secondaryY, width: focusedWidth, height: secondaryHeight),
            CGRect(x: focusedWidth + spacing, y: secondaryY, width: spaceWidth, height: secondaryHeight),
            CGRect(x: focusedWidth + spacing + spaceWidth + spacing, y: secondaryY, width: statusWidth, height: secondaryHeight),
        ]
    }

    /// Cuántas ventanas caben en la fila de la sección de las ventanas
    static func chipCapacity(sectionWidth: CGFloat) -> Int {
        let room = sectionWidth - 2 * padding
        return min(maxChips, max(1, Int((room + chipSpacing) / (chipMinWidth + chipSpacing))))
    }

    /// Cuántas ventanas se dibujan: si no caben todas, la última casilla es el «+n»
    static func visibleChips(windowCount: Int, capacity: Int) -> Int {
        windowCount <= capacity ? windowCount : max(0, capacity - 1)
    }

    static func frames(width: CGFloat, windowCount: Int) -> DesktopPanelFrames {
        let parts = sections(width: width)
        var frames = DesktopPanelFrames()
        (frames.windowsSection, frames.layoutSection, frames.focusedSection, frames.spaceSection, frames.statusSection) =
            (parts[0], parts[1], parts[2], parts[3], parts[4])

        // Las ventanas: la fila reparte el ancho entre todas, como un `flex: 1`
        let windows = frames.windowsSection
        let rowY = windows.minY + padding + headerHeight + 8
        let room = windows.width - 2 * padding
        let capacity = chipCapacity(sectionWidth: windows.width)
        let shown = visibleChips(windowCount: windowCount, capacity: capacity)
        let hasOverflow = windowCount > shown
        let chipsRoom = hasOverflow ? room - overflowWidth - chipSpacing : room
        if shown > 0 {
            let each = (chipsRoom - CGFloat(shown - 1) * chipSpacing) / CGFloat(shown)
            frames.chips = (0..<shown).map {
                CGRect(x: windows.minX + padding + CGFloat($0) * (each + chipSpacing), y: rowY, width: each, height: chipHeight)
            }
        }
        if hasOverflow {
            frames.overflow = CGRect(x: windows.maxX - padding - overflowWidth, y: rowY, width: overflowWidth, height: chipHeight)
        }
        frames.stack = [
            DesktopPanelFrames.Button(control: .stack(forward: false), frame: mini(0, of: 2, in: windows, top: windows.minY + padding)),
            DesktopPanelFrames.Button(control: .stack(forward: true), frame: mini(1, of: 2, in: windows, top: windows.minY + padding)),
        ]

        // La distribución: el «Recordar en el N» en la cabecera, el segmentado y cuatro botones de icono
        let layout = frames.layoutSection
        frames.remember.frame = CGRect(
            x: layout.maxX - padding - pillSize.width, y: layout.minY + padding - 2, width: pillSize.width, height: pillSize.height
        )
        let buttonsWidth = 4 * iconButtonSize.width + 4 * iconSpacing
        let trackWidth = max(0, layout.width - 2 * padding - buttonsWidth)
        frames.segmentedTrack = CGRect(x: layout.minX + padding, y: rowY, width: trackWidth, height: segmentedHeight)
        // BSP y Pila miden lo mismo y Flotante, un poco más (1, 1 y 1,4)
        let inner = trackWidth - 2 * segmentedInset
        let unit = inner / 3.4
        var x = frames.segmentedTrack.minX + segmentedInset
        for (layoutKind, units) in [(YabaiLayout.bsp, 1.0), (.stack, 1.0), (.float, 1.4)] {
            let widthOfSegment = unit * units
            frames.segments.append(DesktopPanelFrames.Button(
                control: .layout(layoutKind),
                frame: CGRect(x: x, y: rowY + segmentedInset, width: widthOfSegment, height: segmentedHeight - 2 * segmentedInset)
            ))
            x += widthOfSegment
        }
        var iconX = frames.segmentedTrack.maxX + iconSpacing
        for control in [DesktopControl.balance, .rotate, .mirror(.x), .mirror(.y)] {
            frames.layoutIcons.append(DesktopPanelFrames.Button(
                control: control, frame: CGRect(origin: CGPoint(x: iconX, y: rowY), size: iconButtonSize)
            ))
            iconX += iconButtonSize.width + iconSpacing
        }

        // La ventana enfocada: botones de texto, y dos botoncitos (en todos los escritorios, encima) en la cabecera
        let focused = frames.focusedSection
        let secondaryRowY = focused.minY + secondaryInsetY + headerHeight + 6
        let natural = focusedWidths.reduce(0, +) + CGFloat(focusedWidths.count - 1) * textButtonSpacing
        let scale = min(1, (focused.width - 2 * padding) / natural)
        var textX = focused.minX + padding
        for (index, control) in focusedControls.enumerated() {
            let buttonWidth = focusedWidths[index] * scale
            frames.focusedText.append(DesktopPanelFrames.Button(
                control: control, frame: CGRect(x: textX, y: secondaryRowY, width: buttonWidth, height: textButtonHeight)
            ))
            textX += buttonWidth + textButtonSpacing * scale
        }
        frames.focusedMini = [
            DesktopPanelFrames.Button(control: .sticky, frame: mini(0, of: 2, in: focused, top: focused.minY + secondaryInsetY - 2)),
            DesktopPanelFrames.Button(control: .above, frame: mini(1, of: 2, in: focused, top: focused.minY + secondaryInsetY - 2)),
        ]

        // El escritorio: el interruptor de la presentación, y quitar y mover en la cabecera
        let space = frames.spaceSection
        frames.presentation.frame = CGRect(x: space.minX + padding, y: secondaryRowY, width: space.width - 2 * padding, height: textButtonHeight)
        frames.spaceMini = [
            DesktopPanelFrames.Button(control: .removeSpace, frame: mini(0, of: 3, in: space, top: space.minY + secondaryInsetY - 2)),
            DesktopPanelFrames.Button(control: .moveSpace(forward: false), frame: mini(1, of: 3, in: space, top: space.minY + secondaryInsetY - 2)),
            DesktopPanelFrames.Button(control: .moveSpace(forward: true), frame: mini(2, of: 3, in: space, top: space.minY + secondaryInsetY - 2)),
        ]

        // yabai: el botón de la chuleta
        let status = frames.statusSection
        frames.skhd.frame = CGRect(x: status.minX + padding, y: secondaryRowY, width: min(skhdWidth, status.width - 2 * padding), height: textButtonHeight)
        return frames
    }

    /// El botoncito número `index` de `count`, pegado a la derecha de la cabecera de una sección
    private static func mini(_ index: Int, of count: Int, in section: CGRect, top: CGFloat) -> CGRect {
        let total = CGFloat(count) * miniSize.width + CGFloat(count - 1) * miniSpacing
        let x = section.maxX - padding - total + CGFloat(index) * (miniSize.width + miniSpacing)
        return CGRect(x: x, y: top, width: miniSize.width, height: miniSize.height)
    }

    /// El botón o la ventana bajo un punto del panel. `windowIDs` son las ventanas en orden; solo cuentan las que se dibujan
    static func control(at point: CGPoint, windowIDs: [Int], width: CGFloat) -> DesktopControl? {
        let frames = frames(width: width, windowCount: windowIDs.count)
        for (slot, frame) in frames.chips.enumerated() where frame.contains(point) { return .window(windowIDs[slot]) }
        return frames.buttons.first { $0.frame.contains(point) }?.control
    }
}

extension IslandExpandedLayout {
    /// El panel de yabai, en coordenadas de la isla (origen arriba a la izquierda). Solo existe en Escritorios, con el panel activado
    func desktopPanelFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard tab == .desktops, hasDesktopPanel else { return nil }
        return CGRect(
            x: (islandWidth - mediaWidth) / 2, y: topHeight + Self.gapBelowNotch + Self.cardHeight + DesktopPanelLayout.gap,
            width: mediaWidth, height: DesktopPanelLayout.height
        )
    }

    /// La tarjeta «+» que crea un escritorio, a la derecha de la última. Solo con el panel de yabai
    func addCardFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard tab == .desktops, hasDesktopPanel, !spaces.isEmpty else { return nil }
        let x = (islandWidth - cardRowWidth) / 2 + cardsWidth + Self.cardSpacing
        return CGRect(x: x, y: topHeight + Self.gapBelowNotch, width: Self.addCardWidth, height: Self.cardHeight)
    }

    func desktopControl(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat, windowIDs: [Int]) -> DesktopControl? {
        if let add = addCardFrame(islandWidth: islandWidth, topHeight: topHeight), add.contains(point) { return .newSpace }
        guard let frame = desktopPanelFrame(islandWidth: islandWidth, topHeight: topHeight), frame.contains(point) else { return nil }
        return DesktopPanelLayout.control(
            at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), windowIDs: windowIDs, width: frame.width
        )
    }
}

// MARK: - Soltar una ventana sobre una tarjeta

enum DesktopDrop {
    /// A qué escritorio se mueve una ventana del panel que se suelta ahí: solo sobre la tarjeta de otro escritorio, que no sea uno a pantalla
    /// completa (a esos no se mueven ventanas), y con el puntero ya fuera del botón que se pulsó
    static func target(pressed: DesktopControl, under control: DesktopControl?, space: SpaceSummary?) -> (window: Int, space: Int)? {
        guard case .window(let id) = pressed, control != pressed, let space, !space.isFocused, !space.isFullscreen else { return nil }
        return (id, space.index)
    }
}

// MARK: - Cuando yabai dice que no

enum DesktopControlText {
    /// Qué decir si una acción falló. Nada de lo que escribe yabai se loguea: puede llevar nombres de ventanas
    static func message(for error: YabaiError, action: YabaiAction, scriptingAddition: Bool) -> String {
        switch error {
        case .notRunning: return "yabai no responde"
        case .notInstalled: return "yabai no está instalado"
        case .timedOut: return "yabai tardó demasiado"
        case .decoding: return "No se entendió a yabai"
        case .commandFailed(_, let stderr):
            let lower = stderr.lowercased()
            if lower.contains("scripting") || lower.contains("integrity") || lower.contains("osax") { return needsScriptingAddition }
            // Sin explicación y de las que la necesitan, es lo más probable
            if stderr.isEmpty, action.scriptingAddition != .none, !scriptingAddition { return needsScriptingAddition }
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "yabai no pudo hacerlo" : String(line.prefix(70))
        }
    }

    static let needsScriptingAddition = "Necesita la scripting addition: sudo yabai --load-sa"
}
