import AppKit
import Foundation
import Observation
import os

// El módulo Portapapeles de la pestaña Utilidades: el historial de lo que copias, las herramientas de desarrollador y el selector de
// color.
//
// macOS pide permiso para leer el portapapeles sin que el usuario pegue (`NSPasteboard.accessBehavior`, desde la 15.4): por defecto
// pregunta cada vez que una app lo lee por programa. Por eso:
//   - el historial está apagado hasta que el usuario lo enciende (un clic en el módulo o en Ajustes), y ese clic es la única lectura
//     que se hace para que macOS pregunte;
//   - solo apunta lo que copias mientras macOS dice «Permitir siempre» (`alwaysAllow`); con «preguntar» no lee solo (cada copia
//     sacaría un aviso) y el módulo manda a Ajustes del Sistema;
//   - las herramientas leen el portapapeles al pulsar un botón: ese clic es del usuario.
// El historial vive en memoria (20 copias); en disco solo si se activa en Ajustes. Lo que las apps marcan como oculto o pasajero
// (contraseñas) y las apps de una lista no se guardan. Nunca se escribe en el portapapeles nada que el usuario no haya pedido.

/// El portapapeles del sistema. En los tests, uno falso con la misma forma
@MainActor
protocol ClipboardSource: AnyObject {
    /// Cuenta los cambios. Leerla no pregunta nada al usuario
    var changeCount: Int { get }
    var accessBehavior: ClipboardAccessBehavior { get }
    /// Los tipos que lleva la copia actual
    var types: [String] { get }
    /// El texto: esta lectura es la que macOS puede preguntar al usuario
    func string() -> String?
    /// Escribe un texto. `concealed` lo marca como oculto (`org.nspasteboard.ConcealedType`), para que ni YabaiBar ni otros
    /// historiales lo guarden: lo que sale de transformar una contraseña es tan secreto como ella
    func write(_ text: String, concealed: Bool)
    /// La app de delante: de ella viene, casi seguro, una copia que acaba de aparecer
    var frontmostBundleID: String? { get }
}

@MainActor
final class SystemClipboard: ClipboardSource {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var accessBehavior: ClipboardAccessBehavior {
        // Antes de la 15.4 no había aviso: se lee libremente
        guard #available(macOS 15.4, *) else { return .alwaysAllow }
        switch pasteboard.accessBehavior {
        case .default: return .unasked
        case .ask: return .ask
        case .alwaysAllow: return .alwaysAllow
        case .alwaysDeny: return .alwaysDeny
        @unknown default: return .ask
        }
    }

    var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }

    func string() -> String? { pasteboard.string(forType: .string) }

    func write(_ text: String, concealed: Bool) {
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        // `declareTypes` ya vacía el portapapeles
        pasteboard.declareTypes(concealed ? [.string, concealedType] : [.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        if concealed { pasteboard.setData(Data(), forType: concealedType) }
    }

    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
}

/// El cuentagotas. En los tests, uno falso
@MainActor
protocol ColorPicking: AnyObject {
    /// El color elegido, o nil si se cancela (Esc)
    func pick(_ completion: @escaping @MainActor (RGBColor?) -> Void)
}

@MainActor
final class SystemColorPicker: ColorPicking {
    private let sampler = NSColorSampler()

    func pick(_ completion: @escaping @MainActor (RGBColor?) -> Void) {
        sampler.show { color in
            let rgb = color.flatMap { $0.usingColorSpace(.sRGB) }.map {
                RGBColor(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent))
            }
            Task { @MainActor in completion(rgb) }
        }
    }
}

/// El historial en disco, solo si el usuario lo pide. Lleva lo que copiaste: la carpeta y el archivo son solo del usuario
struct ClipboardPersistence {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "YabaiBar").appending(path: "clipboard-history.json")
    }

    /// Más que 20 copias de 100 KB con todo escapado: un archivo mayor no es nuestro
    static let maxFileBytes = 8_000_000

    func load() -> [ClipboardEntry] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxFileBytes, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
    }

    func save(_ entries: [ClipboardEntry]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
@Observable
final class ClipboardStore {
    /// Cada cuánto se mira `changeCount`: es solo un número, y el texto se lee únicamente si cambió
    static let pollInterval: Duration = .seconds(1)
    static let messageDuration: Duration = .seconds(2.5)

    private(set) var history = ClipboardHistory()
    private(set) var colors: ClipboardColors
    private(set) var mode: ClipboardMode = .history
    private(set) var message: ClipboardMessage?
    private(set) var behavior: ClipboardAccessBehavior

    /// Se eligió un color con el cuentagotas y su valor ya está copiado
    @ObservationIgnored var onColorCopied: (@MainActor (String) -> Void)?

    @ObservationIgnored private let source: ClipboardSource
    @ObservationIgnored private let picker: ColorPicking
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let persistence: ClipboardPersistence
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let poller = Poller()
    @ObservationIgnored private var lastChangeCount: Int
    /// La app de delante en el sondeo anterior: una copia de un gestor de contraseñas seguida de un cambio de app en menos de un
    /// segundo se atribuiría a la segunda
    @ObservationIgnored private var lastFrontmost: String?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var messageToken = 0
    @ObservationIgnored private var isStarted = false

    init(
        source: ClipboardSource, picker: ColorPicking, settings: AppSettings, persistence: ClipboardPersistence,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.picker = picker
        self.settings = settings
        self.persistence = persistence
        self.clock = clock
        colors = ClipboardColors(hexes: settings.clipboardColors)
        behavior = source.accessBehavior
        lastChangeCount = source.changeCount
    }

    var state: ClipboardHistoryState {
        #if DEBUG
        if let demoState { return demoState }
        #endif
        return .make(enabled: settings.clipboardHistory, behavior: behavior)
    }

    var snapshot: ClipboardSnapshot {
        .make(mode: mode, state: state, history: history, colors: colors, message: message)
    }

    var isRunning: Bool { poller.isRunning }

    // MARK: - Ciclo de vida

    /// Empieza a seguir los ajustes y, con el historial encendido, el portapapeles. En los tests no se llama
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Logger.tools.info("Portapapeles: en marcha")
        if settings.clipboardPersist { history = ClipboardHistory(entries: persistence.load()) }
        lastChangeCount = source.changeCount
        behavior = source.accessBehavior
        observeSettings()
        apply()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        poller.stop()
        messageTask?.cancel()
        messageTask = nil
    }

    // Los ajustes que cambian qué se mira. El valor se lee dentro del seguimiento y lo que se hace con él, fuera
    private func observeSettings() {
        withObservationTracking {
            _ = settings.clipboardHistory
            _ = settings.clipboardPersist
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.apply()
                self.observeSettings()
            }
        }
    }

    /// Mirar el portapapeles solo con el historial encendido; el disco solo si se pidió
    private func apply() {
        guard settings.clipboardHistory else {
            // Apagado: no mira nada, olvida lo que tenía y borra lo que hubiera en disco
            poller.stop()
            if !history.entries.isEmpty { history.clear() }
            persistence.delete()
            return
        }
        poller.start(interval: Self.pollInterval) { [weak self] _ in self?.poll() }
        if settings.clipboardPersist { save() } else { persistence.delete() }
    }

    // MARK: - El historial

    /// Mira si el portapapeles cambió y, solo entonces y con permiso, lee el texto
    func poll() {
        let current = source.accessBehavior
        if current != behavior { behavior = current }
        let count = source.changeCount
        let frontmost = source.frontmostBundleID
        let previousFrontmost = lastFrontmost
        lastFrontmost = frontmost
        // Sin permiso no se lee nada, y se da por visto lo que haya: al llegar el permiso no se apunta lo de antes
        guard settings.clipboardHistory, current == .alwaysAllow else {
            lastChangeCount = count
            return
        }
        guard count != lastChangeCount else { return }
        let ignored = Set(settings.clipboardIgnoredApps)
        // La copia viene de la app de delante ahora o hace un segundo: si cualquiera de las dos es de la lista, no se guarda
        if ClipboardFilter.shouldSkip(types: source.types, sourceBundleID: frontmost, ignoredApps: ignored)
            || previousFrontmost.map(ignored.contains) == true {
            lastChangeCount = count
            return
        }
        guard let text = source.string() else {
            lastChangeCount = count
            return
        }
        // Si cambió mientras se leía, el texto puede ser de otra copia cuyos tipos no se miraron: se descarta y el próximo sondeo la ve
        guard source.changeCount == count else { return }
        lastChangeCount = count
        if history.add(text, at: clock()), settings.clipboardPersist { save() }
    }

    /// Escribe en el portapapeles y da por vista esa escritura: no es una copia del usuario, y sin esto el sondeo la apuntaría en el
    /// historial como nueva (un resultado hecho a partir de una contraseña incluido)
    private func write(_ text: String, concealed: Bool = false) {
        source.write(text, concealed: concealed)
        lastChangeCount = source.changeCount
    }

    func clearHistory() {
        history.clear()
        if settings.clipboardPersist { save() } else { persistence.delete() }
    }

    private func save() {
        do {
            try persistence.save(history.entries)
        } catch {
            Logger.tools.error("Portapapeles: no se pudo guardar el historial")
        }
    }

    // MARK: - Lo que se pulsa

    func setMode(_ newMode: ClipboardMode) {
        mode = newMode
    }

    /// «Activar el historial» y «Dar acceso»: apagado, lo enciende; sin la primera pregunta de macOS, la provoca con una lectura (la
    /// única que se hace para eso); con «preguntar» o «denegado», lleva a Ajustes del Sistema
    func requestAccess() {
        switch state {
        case .off:
            settings.clipboardHistory = true
            if source.accessBehavior == .unasked { prime() } else { behavior = source.accessBehavior }
        case .needsFirstAccess: prime()
        case .needsAllow, .denied: openPrivacySettings()
        case .recording: break
        }
    }

    // Una sola lectura, a petición del usuario: macOS pregunta, y según lo que conteste el estado cambia. Lo leído no se guarda
    private func prime() {
        _ = source.string()
        behavior = source.accessBehavior
        lastChangeCount = source.changeCount
    }

    /// Ajustes del Sistema › Privacidad y seguridad, donde macOS deja elegir «Permitir» para cada app que ha leído el portapapeles
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") { NSWorkspace.shared.open(url) }
    }

    /// Vuelve a copiar una de las copias de la lista. Se elige por su identificador, el de la fila que se dibujó: la lista pudo moverse
    /// entre que se vio y se pulsó, y por posición se copiaría otra. Sube arriba del historial
    func copy(entryID: String) {
        guard let entry = history.entries.first(where: { $0.id == entryID }) else { return }
        write(entry.text)
        if history.add(entry.text, at: clock()), settings.clipboardPersist { save() }
        show("Copiado", isError: false)
    }

    /// Ejecuta una herramienta: lee el portapapeles (el clic es del usuario), transforma, escribe el resultado y lo confirma. Si la
    /// entrada no vale, lo dice y no toca el portapapeles
    func run(_ tool: DevTool, timeZone: TimeZone = .current) {
        if tool.needsInput, source.accessBehavior == .alwaysDeny {
            show("Permítelo en Ajustes del Sistema", isError: true)
            return
        }
        // Si la copia era de una contraseña (oculta, o de un gestor), el resultado también lo es: se mira antes de leer
        let sensitive = tool.needsInput && (ClipboardFilter.shouldSkip(
            types: source.types, sourceBundleID: source.frontmostBundleID, ignoredApps: Set(settings.clipboardIgnoredApps)
        ) || lastFrontmost.map(Set(settings.clipboardIgnoredApps).contains) == true)
        let input = tool.needsInput ? source.string() : nil
        if tool.needsInput, input == nil, source.accessBehavior != .alwaysAllow {
            show("macOS no dejó leer el texto", isError: true)
            return
        }
        switch DevToolbox.run(tool, input: input, now: clock(), timeZone: timeZone) {
        case .success(let result):
            write(result.text, concealed: sensitive)
            show(result.message, isError: false)
        case .failure(let failure):
            show(failure.message, isError: true)
        }
    }

    // MARK: - Colores

    /// El cuentagotas: copia el valor hexadecimal del color elegido y lo apunta entre las muestras
    func pickColor() {
        picker.pick { [weak self] color in
            guard let self, let color else { return }
            let hex = ColorHex.string(color)
            write(hex)
            colors.add(hex)
            settings.clipboardColors = colors.hexes
            onColorCopied?(hex)
        }
    }

    /// Vuelve a copiar una muestra (0 a 7)
    func copy(swatchAt index: Int) {
        guard colors.hexes.indices.contains(index) else { return }
        write(colors.hexes[index])
        show("\(colors.hexes[index]) copiado", isError: false)
    }

    // MARK: - La confirmación

    private func show(_ text: String, isError: Bool) {
        messageToken += 1
        let token = messageToken
        message = ClipboardMessage(text: text, isError: isError)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration, tolerance: .milliseconds(300))
            guard !Task.isCancelled, let self, messageToken == token else { return }
            message = nil
        }
    }

    #if DEBUG
    /// Lo que había antes de la demo, para devolverlo
    @ObservationIgnored private var beforeDemo: (ClipboardHistory, ClipboardColors, ClipboardAccessBehavior)?
    /// En la demo el módulo se ve grabando, aunque el ajuste real esté apagado
    private var demoState: ClipboardHistoryState?

    /// Para el snapshot de la isla: un historial y unas muestras inventados, sin leer el portapapeles
    func injectDemo(mode demoMode: ClipboardMode) {
        if beforeDemo == nil { beforeDemo = (history, colors, behavior) }
        behavior = .alwaysAllow
        demoState = .recording
        let now = Date()
        history = ClipboardHistory(entries: [
            "https://github.com/jerickgm89/yabaiDynamicIsland", "{\"nombre\":\"yabai\",\"version\":3}", "npm run build -- --watch",
            "a3f5c1e9-7b2d-4c8a-9e10-5d6f7a8b9c0d", "Reunión mañana a las 10:00 con el equipo", "SELECT * FROM usuarios WHERE activo = 1;", "extra",
        ].enumerated().map { ClipboardEntry(text: $1, date: now.addingTimeInterval(-Double($0) * 60)) })
        colors = ClipboardColors(hexes: ["#4C8DFF", "#34C759", "#FF9F0A", "#FF453A", "#BF5AF2", "#FFFFFF"])
        mode = demoMode
    }

    /// Lo que se dibuja en el snapshot: lo que copiaste de verdad no se guarda en una imagen (el archivo queda en la caché); solo lo
    /// inventado de la demo se ve
    var snapshotForImage: ClipboardSnapshot {
        var shot = snapshot
        if beforeDemo == nil {
            shot.rows = shot.rows.map { ClipboardSnapshot.Row(id: $0.id, preview: String(repeating: "•", count: min($0.preview.count, 14))) }
        }
        return shot
    }

    func resetInjected() {
        guard let beforeDemo else { return }
        (history, colors, behavior) = beforeDemo
        mode = .history
        demoState = nil
        self.beforeDemo = nil
    }
    #endif
}
