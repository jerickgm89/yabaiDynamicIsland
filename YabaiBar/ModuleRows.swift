import CoreGraphics
import Foundation

// Lógica pura de los módulos de Desarrollador que son una lista de filas (Puertos y Docker): qué fila dice qué, qué botones
// tiene y dónde está cada cosa para dibujarla y para resolver los clics, que no llegan a los botones de SwiftUI
// (ajuste 8). Cada módulo reparte su información en `ModuleRow`s; la vista y los clics solo conocen esto.

/// Lo que se puede hacer con una fila. Cada módulo decide qué significa (DevTools.perform)
enum RowAction: String, Hashable, Sendable {
    /// Abrir en el navegador
    case open
    /// Copiar la URL
    case copy
    /// Cerrar el proceso
    case close
    /// Parar el contenedor o el proyecto
    case stop
    case restart
    case start
    /// Docker: ver los contenedores parados, y volver a los que están en marcha
    case showStopped
    case hideStopped
    /// Claude Code: llevar a la app de la sesión
    case activate
    /// Claude Code: conectar los hooks (abre Ajustes)
    case connect

    var symbol: String {
        switch self {
        case .open: "arrow.up.right.square"
        case .copy: "doc.on.doc"
        case .close: "xmark"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .start: "play.fill"
        case .showStopped: "chevron.down"
        case .hideStopped: "chevron.up"
        case .activate: "arrow.up.forward.app"
        case .connect: "link"
        }
    }

    /// Lo que quita o para algo: se dibuja en rojo
    var isDestructive: Bool { self == .close || self == .stop }

    /// Cómo se lee en voz alta o en el log
    var title: String {
        switch self {
        case .open: "Abrir en el navegador"
        case .copy: "Copiar la URL"
        case .close: "Cerrar"
        case .stop: "Parar"
        case .restart: "Reiniciar"
        case .start: "Iniciar"
        case .showStopped: "Ver los parados"
        case .hideStopped: "Volver"
        case .activate: "Ir a la sesión"
        case .connect: "Conectar con Claude Code…"
        }
    }
}

/// El color de un punto o de un texto de una fila: azul si algo está en marcha, naranja si espera algo de ti, verde si va
/// bien, rojo si salió mal y gris si no hay nada
enum RowTone: Equatable, Sendable {
    case neutral, active, attention, ok, alert
}

/// Un botón de una fila de un módulo, el que se pulsa
struct ModuleControl: Hashable, Sendable {
    let module: ModuleID
    /// `ModuleRow.id`
    let row: String
    let action: RowAction
}

struct ModuleRow: Equatable, Sendable, Identifiable {
    enum Leading: Equatable, Sendable {
        case none
        /// El puerto, en un tipo de letra fija
        case code(String)
        /// Si el contenedor corre
        case status(isOn: Bool)
        /// Un punto de color
        case dot(RowTone)
    }

    /// Estable entre medidas: es lo que identifica la fila al pulsar un botón
    let id: String
    var leading: Leading = .none
    var title: String
    var detail = ""
    /// Texto a la derecha, del color de `tone`, mientras no se ven los botones: «Trabajando»
    var trailing = ""
    var tone: RowTone = .neutral
    var actions: [RowAction] = []
    /// Lo que hace un clic en la fila fuera de sus botones; nil, nada
    var primaryAction: RowAction?
    /// Se ve apagada: un proceso de otro usuario, un contenedor parado, un aviso
    var isDimmed = false
    /// Los botones se ven siempre, y no solo con el puntero encima
    var showsActionsAlways = false
}

/// Lo que enseña un módulo de filas: lo que dice su cabecera y las filas, que como mucho son 3
struct ModuleRowsContent: Equatable, Sendable {
    /// A la derecha de la cabecera: «3 abiertos»
    var summary: String
    var rows: [ModuleRow]
    /// Cuando no hay filas que enseñar: Docker parado, nada abierto
    var notice: Notice?

    struct Notice: Equatable, Sendable {
        var title: String
        var subtitle: String?
    }
}

// Dónde va cada cosa dentro de un módulo: el margen de 10, la cabecera de 14, 6 de hueco, y debajo hasta 3 filas de 22.
// Los botones de una fila miden 20, van pegados a la derecha con 2 de separación y 2 de margen
enum ModuleRowLayout {
    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 14
    static let headerGap: CGFloat = 6
    static let rowHeight: CGFloat = 22
    static let maxRows = 3
    static let buttonSize: CGFloat = 20
    static let buttonSpacing: CGFloat = 2
    static let buttonInset: CGFloat = 2

    /// La fila número `index`, en coordenadas del módulo (origen arriba a la izquierda)
    static func rowFrame(_ index: Int, in cell: CGSize) -> CGRect {
        CGRect(
            x: padding, y: padding + headerHeight + headerGap + CGFloat(index) * rowHeight,
            width: cell.width - 2 * padding, height: rowHeight
        )
    }

    /// Lo que ocupan `count` botones juntos
    static func buttonsWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * buttonSize + CGFloat(count - 1) * buttonSpacing
    }

    /// Lo que miden las filas, todas juntas: hasta `maxRows`
    static let rowsHeight = CGFloat(maxRows) * rowHeight

    /// La fila bajo un punto del módulo, o nil en la cabecera, en los márgenes y debajo de la última
    static func rowIndex(at point: CGPoint, rowCount: Int, cell: CGSize) -> Int? {
        (0..<min(rowCount, maxRows)).first { rowFrame($0, in: cell).contains(point) }
    }

    /// Los botones de una fila, de izquierda a derecha, pegados a su borde derecho
    static func buttonFrames(actionCount: Int, in row: CGRect) -> [CGRect] {
        guard actionCount > 0 else { return [] }
        let width = buttonsWidth(count: actionCount)
        let x = row.maxX - buttonInset - width
        let y = row.minY + (row.height - buttonSize) / 2
        return (0..<actionCount).map { index in
            CGRect(x: x + CGFloat(index) * (buttonSize + buttonSpacing), y: y, width: buttonSize, height: buttonSize)
        }
    }
}

extension IslandExpandedLayout {
    /// La fila de un módulo de Desarrollador bajo un punto de la isla (origen arriba a la izquierda), con su marco en
    /// coordenadas de la isla. Fuera de esa pestaña no hay ninguna
    func moduleRow(
        at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat, rows: [ModuleID: [ModuleRow]]
    ) -> (module: ModuleID, row: ModuleRow, frame: CGRect)? {
        guard tab == .developer else { return nil }
        let origin = activityOrigin(islandWidth: islandWidth, topHeight: topHeight)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        for cell in developerGrid.cells where cell.frame.contains(local) {
            guard let moduleRows = rows[cell.module] else { return nil }
            let inside = CGPoint(x: local.x - cell.frame.minX, y: local.y - cell.frame.minY)
            guard let index = ModuleRowLayout.rowIndex(at: inside, rowCount: moduleRows.count, cell: cell.frame.size) else {
                return nil
            }
            let frame = ModuleRowLayout.rowFrame(index, in: cell.frame.size)
                .offsetBy(dx: cell.frame.minX + origin.x, dy: cell.frame.minY + origin.y)
            return (cell.module, moduleRows[index], frame)
        }
        return nil
    }

    /// El botón de una fila bajo un punto, con un poco de margen para acertarlo fácil. Los botones de las filas que solo
    /// se ven con el puntero encima también responden: el puntero ya está en ellas
    func moduleControl(
        at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat, rows: [ModuleID: [ModuleRow]]
    ) -> ModuleControl? {
        guard let hit = moduleRow(at: point, islandWidth: islandWidth, topHeight: topHeight, rows: rows) else { return nil }
        let frames = ModuleRowLayout.buttonFrames(actionCount: hit.row.actions.count, in: hit.frame)
        for (action, frame) in zip(hit.row.actions, frames) where frame.insetBy(dx: -1, dy: -2).contains(point) {
            return ModuleControl(module: hit.module, row: hit.row.id, action: action)
        }
        // Fuera de los botones, lo que haga la fila entera, si hace algo
        return hit.row.primaryAction.map { ModuleControl(module: hit.module, row: hit.row.id, action: $0) }
    }
}
