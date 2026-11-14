import Foundation

// Lo que la isla le pide a yabai (fase 45): cada acción y las órdenes exactas de `yabai -m` que la hacen. Puro: no ejecuta nada, y así
// se prueban los argumentos sin tocar el yabai real. Todas cambian el estado de yabai: el agente no las lanza por su cuenta.
// La sintaxis sale del manual de yabai 7.1.25 (`man yabai`).

enum YabaiLayout: String, CaseIterable, Codable, Sendable {
    case bsp, stack, float

    var title: String {
        switch self {
        case .bsp: "Mosaico"
        case .stack: "Pila"
        case .float: "Flotante"
        }
    }
}

enum YabaiAxis: String, Sendable {
    case x = "x-axis"
    case y = "y-axis"
}

/// El nivel de apilado de una ventana. Cambiarlo necesita la scripting addition
enum YabaiSubLayer: String, Sendable {
    case above, auto
}

/// Una orden suelta de `yabai -m`. `optional`: si falla, la acción sigue (quitar algo que quizá no estaba)
struct YabaiCommand: Equatable, Sendable {
    var arguments: [String]
    var optional = false
}

/// Lo que necesita una acción de la scripting addition de yabai. Hoy no está cargada (cargarla es cosa del usuario: `sudo yabai --load-sa`)
enum ScriptingAdditionNeed: Sendable {
    case none
    /// El manual no dice que la necesite, pero en versiones de macOS recientes puede hacer falta
    case maybe
    case required
}

enum YabaiAction: Equatable, Sendable {
    // El escritorio activo
    case setLayout(YabaiLayout)
    case balance
    case rotate
    case mirror(YabaiAxis)
    /// Quita los márgenes y los huecos entre ventanas, o los devuelve
    case togglePresentation
    // Ventanas
    case focusWindow(Int)
    /// Pasa a la siguiente (o a la anterior) de la pila; al llegar al final da la vuelta (con `stackEdge`)
    case stackStep(forward: Bool)
    case stackEdge(first: Bool)
    // La ventana enfocada
    case toggleFloat, toggleZoomParent, toggleZoomFullscreen, toggleSplit
    /// Del zoom al padre al zoom a todo el escritorio: quita el primero y pone el segundo
    case switchZoomToFullscreen
    case swapWithLargest
    case toggleSticky
    case setSubLayer(YabaiSubLayer)
    case moveWindow(id: Int, toSpace: Int)
    // Escritorios
    case createSpace
    case destroySpace(Int)
    /// Pone el escritorio activo una posición antes (o después)
    case moveSpace(forward: Bool)
    case focusSpace(Int)
    // Lo que la app recuerda y vuelve a aplicar
    case configLayout(space: Int, layout: YabaiLayout)
    case addFloatRule(app: String)
    case removeFloatRule(app: String)

    /// Lo que se escribe en la cabecera al pasar el puntero, o en el mensaje del resultado
    var title: String {
        switch self {
        case .setLayout(let layout): "Distribución: \(layout.title.lowercased())"
        case .balance: "Equilibrar las ventanas"
        case .rotate: "Girar 90°"
        case .mirror(let axis): axis == .x ? "Voltear en horizontal" : "Voltear en vertical"
        case .togglePresentation: "Quitar o poner márgenes y huecos"
        case .focusWindow: "Enfocar la ventana"
        case .stackStep(let forward): forward ? "Siguiente de la pila" : "Anterior de la pila"
        case .stackEdge(let first): first ? "Primera de la pila" : "Última de la pila"
        case .toggleFloat: "Flotante o en mosaico"
        case .toggleZoomParent: "Zoom al padre"
        case .toggleZoomFullscreen: "Zoom a todo el escritorio"
        case .switchZoomToFullscreen: "Zoom a todo el escritorio"
        case .toggleSplit: "Cambiar la división"
        case .swapWithLargest: "Hacerla principal"
        case .toggleSticky: "En todos los escritorios"
        case .setSubLayer(let layer): layer == .above ? "Siempre encima" : "Nivel normal"
        case .moveWindow(_, let space): "Mover al escritorio \(space)"
        case .createSpace: "Nuevo escritorio"
        case .destroySpace(let index): "Quitar el escritorio \(index)"
        case .moveSpace(let forward): forward ? "Mover el escritorio a la derecha" : "Mover el escritorio a la izquierda"
        case .focusSpace(let index): "Ir al escritorio \(index)"
        case .configLayout: "Recordar la distribución"
        case .addFloatRule: "Esta app, siempre flotante"
        case .removeFloatRule: "Esta app, en mosaico"
        }
    }

    /// Si hace falta la scripting addition. Mover una ventana de escritorio no la pide en el manual, pero en macOS recientes
    /// puede necesitarla: se intenta y, si yabai dice que no, se explica
    var scriptingAddition: ScriptingAdditionNeed {
        switch self {
        case .toggleSticky, .setSubLayer, .createSpace, .destroySpace, .moveSpace, .focusSpace: .required
        case .moveWindow: .maybe
        default: .none
        }
    }

    /// Las órdenes, en orden. Si una no opcional falla, no se siguen
    var commands: [YabaiCommand] {
        switch self {
        case .setLayout(let layout): [YabaiCommand(arguments: ["space", "--layout", layout.rawValue])]
        case .balance: [YabaiCommand(arguments: ["space", "--balance"])]
        case .rotate: [YabaiCommand(arguments: ["space", "--rotate", "90"])]
        case .mirror(let axis): [YabaiCommand(arguments: ["space", "--mirror", axis.rawValue])]
        case .togglePresentation:
            [YabaiCommand(arguments: ["space", "--toggle", "padding"]), YabaiCommand(arguments: ["space", "--toggle", "gap"])]
        case .focusWindow(let id): [YabaiCommand(arguments: ["window", "--focus", String(id)])]
        case .stackStep(let forward): [YabaiCommand(arguments: ["window", "--focus", forward ? "stack.next" : "stack.prev"])]
        case .stackEdge(let first): [YabaiCommand(arguments: ["window", "--focus", first ? "stack.first" : "stack.last"])]
        case .toggleFloat: [YabaiCommand(arguments: ["window", "--toggle", "float"])]
        case .toggleZoomParent: [YabaiCommand(arguments: ["window", "--toggle", "zoom-parent"])]
        case .toggleZoomFullscreen: [YabaiCommand(arguments: ["window", "--toggle", "zoom-fullscreen"])]
        case .switchZoomToFullscreen:
            [YabaiCommand(arguments: ["window", "--toggle", "zoom-parent"]), YabaiCommand(arguments: ["window", "--toggle", "zoom-fullscreen"])]
        case .toggleSplit: [YabaiCommand(arguments: ["window", "--toggle", "split"])]
        case .swapWithLargest: [YabaiCommand(arguments: ["window", "--swap", "largest"])]
        case .toggleSticky: [YabaiCommand(arguments: ["window", "--toggle", "sticky"])]
        case .setSubLayer(let layer): [YabaiCommand(arguments: ["window", "--sub-layer", layer.rawValue])]
        case .moveWindow(let id, let space): [YabaiCommand(arguments: ["window", String(id), "--space", String(space)])]
        case .createSpace: [YabaiCommand(arguments: ["space", "--create"])]
        case .destroySpace(let index): [YabaiCommand(arguments: ["space", "--destroy", String(index)])]
        case .moveSpace(let forward): [YabaiCommand(arguments: ["space", "--move", forward ? "next" : "prev"])]
        case .focusSpace(let index): [YabaiCommand(arguments: ["space", "--focus", String(index)])]
        case .configLayout(let space, let layout):
            // La misma orden que usa la isla (`space --layout`), pero con el escritorio por su índice
            [YabaiCommand(arguments: ["space", String(space), "--layout", layout.rawValue])]
        case .addFloatRule(let app):
            // Una regla con la misma etiqueta no se añade dos veces: primero se quita la anterior (si no estaba, no pasa nada), después se
            // añade y se aplica a las ventanas que ya hay
            [
                YabaiCommand(arguments: ["rule", "--remove", YabaiRules.label(for: app)], optional: true),
                YabaiCommand(arguments: ["rule", "--add", "label=\(YabaiRules.label(for: app))", "app=\(YabaiRules.pattern(for: app))", "manage=off"]),
                YabaiCommand(arguments: ["rule", "--apply", YabaiRules.label(for: app)], optional: true),
            ]
        case .removeFloatRule(let app): [YabaiCommand(arguments: ["rule", "--remove", YabaiRules.label(for: app)], optional: true)]
        }
    }

    /// Si la primera orden falla, se prueba esta (la pila no da la vuelta sola: del último pasa al primero)
    var fallback: YabaiAction? {
        if case .stackStep(let forward) = self { return .stackEdge(first: forward) }
        return nil
    }

    /// Cambia lo que se ve (ventanas, distribución, escritorios): tras ella se vuelve a leer
    var changesWorkspace: Bool {
        switch self {
        // Recordar una distribución no cambia nada ahora, y quitar una regla tampoco; añadirla sí (se aplica a las ventanas que hay)
        case .configLayout, .removeFloatRule: false
        default: true
        }
    }
}

/// Las reglas «esta app, siempre flotante»: yabai las pierde al reiniciarse, y YabaiBar las vuelve a añadir
enum YabaiRules {
    static let labelPrefix = "yb_float_"

    /// Lo que yabai toma como etiqueta: solo letras, cifras y `_`, con un resumen del nombre completo para que dos apps parecidas no choquen
    static func label(for app: String) -> String {
        let clean = app.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "_"
        }
        let base = String(clean.prefix(24)).lowercased()
        // FNV-1a de 32 bits del nombre entero: estable entre ejecuciones (hashValue no lo es)
        var hash: UInt32 = 2_166_136_261
        for byte in app.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return "\(labelPrefix)\(base)_\(String(hash, radix: 16))"
    }

    /// Las marcas de dirección que yabai antepone a algunos nombres (U+200E en WhatsApp): el nombre guardado va sin ellas, y la regla las admite
    /// al principio y al final. Van dentro de un corchete: casa con cualquiera de sus bytes, y así sirve igual con una regex por bytes (la
    /// `regcomp` de libc en la configuración regional C, que es lo que usa yabai) que con una de caracteres
    private static let directionMarks = "[\u{200E}\u{200F}]*"

    /// La expresión regular que casa exactamente con el nombre de la app: escapa lo que significa algo en una expresión regular
    static func pattern(for app: String) -> String {
        let special: Set<Character> = [".", "[", "]", "{", "}", "(", ")", "\\", "*", "+", "?", "|", "^", "$"]
        var escaped = ""
        for character in app {
            if special.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "^" + directionMarks + escaped + directionMarks + "$"
    }

    /// Un nombre de app que se puede guardar y pasar a yabai: sin saltos de línea ni caracteres de control, y no vacío
    static func clean(_ app: String) -> String? {
        let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))
        let trimmed = app.trimmingCharacters(in: invisible)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }
}

/// La distribución que el usuario eligió para cada escritorio, para volver a ponerla cuando yabai se reinicia
enum LayoutMemory {
    /// Qué distribuciones hay que volver a aplicar: las recordadas que ya no coinciden con las de yabai. Un escritorio que ya no existe se
    /// salta
    static func reapply(remembered: [Int: YabaiLayout], current: [SpaceSummary]) -> [YabaiAction] {
        remembered.keys.sorted().compactMap { index in
            guard let space = current.first(where: { $0.index == index }), let wanted = remembered[index],
                  let layout = space.layout, layout != wanted else { return nil }
            return .configLayout(space: index, layout: wanted)
        }
    }

    /// Quitar el escritorio `removed` baja un número los que venían detrás, y su distribución se va con él
    static func afterDestroying(_ removed: Int, in layouts: [Int: YabaiLayout]) -> [Int: YabaiLayout] {
        var result: [Int: YabaiLayout] = [:]
        for (index, layout) in layouts where index != removed { result[index > removed ? index - 1 : index] = layout }
        return result
    }

    /// Mover el escritorio activo a un lado cambia su puesto con el del vecino: lo recordado de uno pasa al otro
    static func afterMoving(_ active: Int, forward: Bool, in layouts: [Int: YabaiLayout]) -> [Int: YabaiLayout] {
        let neighbour = forward ? active + 1 : active - 1
        guard neighbour >= 1 else { return layouts }
        var result = layouts
        result[active] = layouts[neighbour]
        result[neighbour] = layouts[active]
        return result
    }

    /// Lo guardado en `UserDefaults` (claves de texto) a distribuciones; lo que no vale se descarta
    static func decode(_ stored: [String: String]) -> [Int: YabaiLayout] {
        var result: [Int: YabaiLayout] = [:]
        for (key, value) in stored {
            if let index = Int(key), (1...9999).contains(index), let layout = YabaiLayout(rawValue: value) { result[index] = layout }
        }
        return result
    }

    static func encode(_ layouts: [Int: YabaiLayout]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: layouts.map { (String($0.key), $0.value.rawValue) })
    }
}

/// La scripting addition de yabai: sin ella, mover escritorios, cambiar de uno al instante o fijar una ventana no funcionan. Cargarla es
/// cosa del usuario (`sudo yabai --load-sa`): la app nunca lo hace. Cuando está cargada, su carga en el Dock abre un socket en /tmp
enum ScriptingAddition {
    static func socketPath(user: String) -> String { "/tmp/yabai-sa_\(user).socket" }

    /// La clave de `UserDefaults` que la da por cargada aunque no se vea el socket (`defaults write com.jerickdev.yabaibar
    /// yabaiAssumeScriptingAddition -bool true`), por si algún día el socket se llamara de otra forma
    static let overrideKey = "yabaiAssumeScriptingAddition"

    /// Si parece cargada (el socket existe, o el usuario dice que sí). Una aproximación: un socket que queda huérfano al reiniciar el Dock la
    /// haría parecer cargada, y sin ella, `space --focus` sale con 0 sin hacer nada (por eso el cambio al instante vuelve al atajo si no cambia).
    /// Sin ella, las acciones que la necesitan se atenúan y no se intentan
    static func isLoaded(
        user: String = NSUserName(), exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: overrideKey) || exists(socketPath(user: user))
    }
}
