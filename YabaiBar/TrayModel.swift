import CoreGraphics
import Foundation

// Lógica pura del módulo Bandeja de Utilidades (fase 44): la lista de archivos que se sueltan en la isla, sus reglas y dónde está cada
// cosa para dibujarla y resolver los clics. Nada de aquí toca el disco ni el Finder: `TrayStore` lo hace.
//
// La bandeja guarda referencias, no copias: la ruta y un marcador (bookmark) del archivo, que sigue al archivo si lo renombras o lo
// mueves. Si desaparece, el elemento se marca como que falta; nunca se abre ni se ejecuta nada de lo que hay en ella.

// MARK: - Elementos

struct TrayItem: Equatable, Identifiable, Codable, Sendable {
    var id = UUID().uuidString
    var path: String
    /// Sigue al archivo si se renombra o se mueve. nil si no se pudo crear
    var bookmark: Data?
    var added: Date

    /// El nombre del archivo para enseñarlo: sin saltos de línea ni caracteres de control, que un nombre puede traer
    var name: String { TrayShelf.displayName(of: path) }
}

/// Lo que se averiguó de un elemento al mirar el disco: dónde está ahora (nil si ya no está) y un marcador renovado
struct TrayResolution: Equatable, Sendable {
    var id: String
    var path: String?
    var bookmark: Data?
}

/// Lo que se soltó, ya limpio: una ruta absoluta y su marcador
struct TrayDrop: Equatable, Sendable {
    var path: String
    var bookmark: Data?
}

// MARK: - La lista

/// Lo soltado, del más nuevo al más viejo: como mucho 12
struct TrayShelf: Equatable, Sendable {
    static let capacity = 12
    static let maxPathLength = 4096

    private(set) var items: [TrayItem]

    /// Lo que viene de fuera (lo guardado en disco) pasa por las mismas reglas que lo que se suelta ahora: rutas válidas, sin
    /// repetidos, con identificadores distintos y como mucho 12
    init(items: [TrayItem] = []) {
        var paths: Set<String> = []
        var ids: Set<String> = []
        var kept: [TrayItem] = []
        for var item in items where Self.isValid(path: item.path) && paths.insert(item.path).inserted {
            if !ids.insert(item.id).inserted {
                item.id = UUID().uuidString
                ids.insert(item.id)
            }
            kept.append(item)
            if kept.count == Self.capacity { break }
        }
        self.items = kept
    }

    /// Una ruta que vale: absoluta, sin caracteres nulos, no la raíz y de un tamaño razonable
    static func isValid(path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= maxPathLength && !path.contains("\0")
    }

    /// La ruta de un archivo soltado, o nil si no es un archivo local. Resuelve las referencias de archivo
    /// («file:///.file/id=…») a su ruta y quita los `..`. Una URL con otro equipo (`file://otro/etc/hosts`) no es un archivo de aquí
    static func path(of url: URL) -> String? {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host?.lowercased()) else { return nil }
        let resolved = (url as NSURL).filePathURL ?? url
        let path = resolved.standardizedFileURL.path
        return isValid(path: path) ? path : nil
    }

    /// Lo que se enseña como nombre: el último componente, con lo que no se ve convertido en espacios
    static func displayName(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(sin nombre)" : trimmed
    }

    /// Apunta lo que se soltó: el primero queda arriba. Uno que ya estaba sube arriba en vez de salir dos veces, y el límite
    /// se cumple quitando los más viejos. Devuelve cuántos se apuntaron
    @discardableResult
    mutating func add(_ drops: [TrayDrop], at date: Date) -> Int {
        var added = 0
        // Una sola suelta no pasa del límite, y los repetidos dentro de ella cuentan una vez
        var seen: Set<String> = []
        let fresh = drops.filter { Self.isValid(path: $0.path) && seen.insert($0.path).inserted }.prefix(Self.capacity)
        for drop in fresh.reversed() {
            items.removeAll { $0.path == drop.path }
            items.insert(TrayItem(path: drop.path, bookmark: drop.bookmark, added: date), at: 0)
            added += 1
        }
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        return added
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    mutating func clear() {
        items = []
    }

    /// Pone al día las rutas de lo que se movió o se renombró. Si el elemento llega a la ruta de otro que ya estaba, queda el otro
    mutating func apply(_ resolutions: [TrayResolution]) {
        for resolution in resolutions {
            guard let index = items.firstIndex(where: { $0.id == resolution.id }) else { continue }
            if let bookmark = resolution.bookmark { items[index].bookmark = bookmark }
            guard let path = resolution.path, path != items[index].path, Self.isValid(path: path) else { continue }
            if items.contains(where: { $0.path == path && $0.id != resolution.id }) {
                items.remove(at: index)
            } else {
                items[index].path = path
            }
        }
    }

    /// Los que no están en ninguna de las resoluciones con ruta
    static func missing(_ resolutions: [TrayResolution]) -> Set<String> {
        Set(resolutions.filter { $0.path == nil }.map(\.id))
    }
}

// MARK: - Lo que enseña el módulo

struct TraySnapshot: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        /// Para pedir el ícono. Vacía: un ícono genérico (el snapshot de DEBUG no enseña tus archivos)
        var path: String
        var isMissing: Bool
        /// Ya se comprobó en el disco que existe: solo entonces se le pide su ícono real, que toca el disco
        var isVerified: Bool
    }

    var items: [Item]

    static func make(shelf: TrayShelf, missing: Set<String>, verified: Set<String>) -> TraySnapshot {
        TraySnapshot(items: shelf.items.map {
            Item(id: $0.id, name: $0.name, path: $0.path, isMissing: missing.contains($0.id), isVerified: verified.contains($0.id))
        })
    }
}

// MARK: - Dónde está cada cosa

/// Lo que se pulsa en el módulo, por el identificador del elemento y no por su posición: la lista pudo moverse entre que se vio y se pulsó
enum TrayControl: Hashable, Sendable {
    /// Un archivo: un clic lo muestra en el Finder y arrastrarlo lo saca de la isla
    case item(String)
    /// La «×» de un archivo: quitarlo de la bandeja
    case remove(String)

    var isRemove: Bool {
        if case .remove = self { true } else { false }
    }
}

// El módulo ocupa lo que sobra de la segunda fila de Utilidades (unos 152 × 112 en el 16"): la cabecera y debajo una rejilla
// de 3 filas de íconos, con tantas columnas como quepan (4 en 152 pt). Cada ícono es un archivo; el nombre sale en la cabecera
// al pasar el puntero
enum TrayModuleLayout {
    static let padding: CGFloat = 8
    static let headerHeight: CGFloat = 14
    static let bodyY: CGFloat = 28
    static let rows = 3
    static let minCellWidth: CGFloat = 30
    static let maxColumns = 6
    static let cellSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 2
    static let removeSize: CGFloat = 12

    static func columns(in size: CGSize) -> Int {
        let room = size.width - 2 * padding + cellSpacing
        return min(maxColumns, max(1, Int(room / (minCellWidth + cellSpacing))))
    }

    /// Cuántos íconos caben: los que no caben siguen en la lista, aunque no se vean
    static func slotCount(in size: CGSize) -> Int { columns(in: size) * rows }

    static func itemFrame(_ slot: Int, in size: CGSize) -> CGRect {
        let columns = CGFloat(columns(in: size))
        let width = max(0, (size.width - 2 * padding - (columns - 1) * cellSpacing) / columns)
        let height = max(0, (size.height - bodyY - padding - CGFloat(rows - 1) * rowSpacing) / CGFloat(rows))
        return CGRect(
            x: padding + CGFloat(slot % Int(columns)) * (width + cellSpacing),
            y: bodyY + CGFloat(slot / Int(columns)) * (height + rowSpacing), width: width, height: height
        )
    }

    /// La «×», en la esquina de arriba a la derecha del ícono
    static func removeFrame(_ slot: Int, in size: CGSize) -> CGRect {
        let item = itemFrame(slot, in: size)
        return CGRect(x: item.maxX - removeSize, y: item.minY, width: removeSize, height: removeSize)
    }

    /// El área donde se suelta: todo el cuerpo del módulo, para que no haya que apuntar a un ícono
    static func bodyFrame(in size: CGSize) -> CGRect {
        CGRect(x: padding, y: bodyY, width: size.width - 2 * padding, height: size.height - bodyY - padding)
    }

    /// Lo que hay bajo un punto del módulo, con los identificadores de los elementos dibujados, en orden
    static func control(at point: CGPoint, ids: [String], in size: CGSize) -> TrayControl? {
        for (slot, id) in ids.prefix(slotCount(in: size)).enumerated() {
            if removeFrame(slot, in: size).contains(point) { return .remove(id) }
            if itemFrame(slot, in: size).contains(point) { return .item(id) }
        }
        return nil
    }
}

extension IslandExpandedLayout {
    /// El módulo Bandeja, en coordenadas de la isla (origen arriba a la izquierda). Solo existe en Utilidades
    func trayFrame(islandWidth: CGFloat, topHeight: CGFloat) -> CGRect? {
        guard tab == .utilities, let cell = utilityModules.cells.first(where: { $0.module == .tray }) else { return nil }
        let origin = activityOrigin(islandWidth: islandWidth, topHeight: topHeight)
        return cell.frame.offsetBy(dx: origin.x, dy: origin.y + Self.activityHeight + Self.activityGap)
    }

    func trayControl(at point: CGPoint, islandWidth: CGFloat, topHeight: CGFloat, ids: [String]) -> TrayControl? {
        guard let frame = trayFrame(islandWidth: islandWidth, topHeight: topHeight), frame.contains(point) else { return nil }
        return TrayModuleLayout.control(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), ids: ids, in: frame.size)
    }
}
