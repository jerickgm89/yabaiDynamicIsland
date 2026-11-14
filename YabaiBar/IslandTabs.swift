import CoreGraphics
import Foundation

// Lógica pura de las pestañas de la isla abierta. El escritorio activo no es una pestaña: las alas de la franja del
// notch lo enseñan en las tres, igual que con la isla cerrada.

/// Las pestañas de la isla abierta, en el orden en que se dibujan las píldoras y se pasa de una a otra
enum IslandTab: Int, CaseIterable, Hashable, Sendable {
    /// Las tarjetas de los escritorios
    case desktops
    /// El Pomodoro, la música, el calendario y el portapapeles
    case utilities
    /// El monitor del sistema, los puertos, Docker, Git, Claude Code y los avisos
    case developer

    var title: String {
        switch self {
        case .desktops: "Escritorios"
        case .utilities: "Utilidades"
        case .developer: "Desarrollador"
        }
    }

    var symbol: String {
        switch self {
        case .desktops: "square.grid.2x2"
        case .utilities: "slider.horizontal.3"
        case .developer: "terminal"
        }
    }

    /// Cómo se abre la isla
    enum Opening {
        /// Con el puntero: se abre para cambiar de escritorio
        case pointer
        /// Con el atajo o el gesto: donde se dejó
        case keyboard
        /// Al arrastrar un archivo sobre la isla: en Utilidades, donde está la bandeja
        case drop

        /// Las teclas h y l (como en vim) solo se registran abierta con el teclado o el gesto: con el puntero la
        /// intención es el ratón, y no se le quitan esas letras a la app de delante
        var usesVimKeys: Bool { self == .keyboard }
    }

    /// La pestaña que se ve al abrir: con el puntero, los escritorios; con el atajo o el gesto, la última que se usó
    /// (si ya no está entre las visibles, los escritorios)
    static func opening(_ opening: Opening, last: IslandTab, among tabs: [IslandTab]) -> IslandTab {
        switch opening {
        case .pointer: .desktops
        case .keyboard: tabs.contains(last) ? last : .desktops
        case .drop: tabs.contains(.utilities) ? .utilities : .desktops
        }
    }

    enum Step { case previous, next }

    /// La anterior o la siguiente entre las visibles, dando la vuelta: desde la última se vuelve a la primera
    func stepping(_ step: Step, among tabs: [IslandTab]) -> IslandTab {
        guard tabs.count > 1 else { return self }
        let index = tabs.firstIndex(of: self) ?? 0
        let offset = step == .next ? 1 : tabs.count - 1
        return tabs[(index + offset) % tabs.count]
    }
}

/// El punto que avisa de una novedad en una pestaña, en su píldora y en la isla cerrada
enum TabBadge: Equatable, Sendable {
    /// Algo que mirar pronto: un evento del calendario
    case info
    /// Algo espera una respuesta tuya: Claude pregunta
    case attention
    /// Algo salió mal: un comando o el CI fallaron
    case alert

    /// El punto de Desarrollador: naranja mientras una sesión de Claude Code espera tu respuesta, que manda (hay algo parado esperándote), y
    /// si no, la novedad de Git que todavía no has visto: roja si falló el CI de un push, azul si un aviso no llegó a verse
    static func developer(claudeWaiting: Int, news: TabBadge?) -> TabBadge? {
        claudeWaiting > 0 ? .attention : news
    }
}

/// Los módulos de las pestañas Utilidades y Desarrollador
enum ModuleID: String, CaseIterable, Hashable, Sendable {
    case calendar, clipboard, tray
    case system, ports, docker, git, claude, notices

    var tab: IslandTab {
        switch self {
        case .calendar, .clipboard, .tray: .utilities
        case .system, .ports, .docker, .git, .claude, .notices: .developer
        }
    }

    static func modules(of tab: IslandTab) -> [ModuleID] {
        allCases.filter { $0.tab == tab }
    }

    var title: String {
        switch self {
        case .calendar: "Calendario"
        case .clipboard: "Portapapeles"
        case .tray: "Bandeja"
        case .system: "Sistema"
        case .ports: "Puertos"
        case .docker: "Docker"
        case .git: "Git"
        case .claude: "Claude Code"
        case .notices: "Avisos"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .clipboard: "doc.on.clipboard"
        case .tray: "tray"
        case .system: "cpu"
        case .ports: "globe"
        case .docker: "shippingbox"
        case .git: "arrow.triangle.branch"
        case .claude: "sparkles"
        case .notices: "bell"
        }
    }
}

// Dónde va cada módulo de una pestaña, en coordenadas de la zona que ocupan (origen arriba a la izquierda). Se rehace
// con los módulos que haya: si se oculta alguno, los demás ocupan su sitio.
struct ModuleGridLayout: Equatable {
    struct Cell: Equatable {
        let module: ModuleID
        let frame: CGRect
    }

    let cells: [Cell]
    let size: CGSize

    /// Columnas iguales, en filas de `rowHeight`. La última fila, si no se llena, deja libres las columnas del final
    init(modules: [ModuleID], columns: Int, width: CGFloat, rowHeight: CGFloat, spacing: CGFloat) {
        let columns = max(1, columns)
        let column = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        cells = modules.enumerated().map { index, module in
            let x = CGFloat(index % columns) * (column + spacing)
            let y = CGFloat(index / columns) * (rowHeight + spacing)
            return Cell(module: module, frame: CGRect(x: x, y: y, width: column, height: rowHeight))
        }
        size = CGSize(
            width: width,
            height: Self.height(count: modules.count, columns: columns, rowHeight: rowHeight, spacing: spacing)
        )
    }

    /// Una sola fila con anchos fijos; el último módulo ocupa lo que sobra
    init(row modules: [ModuleID], fixedWidths: [CGFloat], width: CGFloat, height: CGFloat, spacing: CGFloat) {
        var x: CGFloat = 0
        var cells: [Cell] = []
        for (index, module) in modules.enumerated() {
            let isLast = index == modules.count - 1
            let cellWidth = isLast || index >= fixedWidths.count ? max(0, width - x) : fixedWidths[index]
            cells.append(Cell(module: module, frame: CGRect(x: x, y: 0, width: cellWidth, height: height)))
            x += cellWidth + spacing
        }
        self.cells = cells
        size = CGSize(width: width, height: modules.isEmpty ? 0 : height)
    }

    /// Lo que mide una rejilla con ese número de módulos: no depende del ancho
    static func height(count: Int, columns: Int, rowHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + max(1, columns) - 1) / max(1, columns)
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing
    }
}
