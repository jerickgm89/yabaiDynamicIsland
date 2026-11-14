import Foundation
import Observation
import os

// El panel de yabai de la pestaña Escritorios: lee las ventanas del escritorio activo y ejecuta lo que se pulsa. Solo mira con la pestaña
// a la vista (una consulta cada 2 s, que son dos `yabai -m query`) y, tras cada acción, vuelve a leer. Todo lo que ejecuta cambia el
// estado de yabai: lo pide el usuario con un clic, nunca la app por su cuenta, salvo lo que recuerda y vuelve a aplicar (`YabaiRestorer`).
// Ni los títulos de las ventanas ni lo que dice yabai van a ningún log.
@MainActor
@Observable
final class DesktopControlStore {
    static let pollInterval: Duration = .seconds(2)
    static let messageDuration: Duration = .seconds(3)

    private(set) var snapshot = DesktopControlSnapshot()

    /// Se ejecutó una acción que cambia lo que se ve: que la isla vuelva a leer los escritorios (el debounce de `SpacesStore` lo junta)
    @ObservationIgnored var onChanged: (@MainActor () -> Void)?
    /// La acción de quitar un escritorio es de las que no se deshacen: pregunta antes. En los tests, una respuesta fija
    @ObservationIgnored var confirm: @MainActor (String, String, String) -> Bool
    /// La isla se cierra antes de preguntar: el aviso es modal y se quedaría detrás de ella
    @ObservationIgnored var onWillAsk: (@MainActor () -> Void)?

    @ObservationIgnored private var isAsking = false
    @ObservationIgnored private let query: any YabaiQuerying
    @ObservationIgnored private let control: any YabaiControlling
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let scriptingAddition: @MainActor () -> Bool
    @ObservationIgnored private let versionProvider: (@Sendable () async -> String?)?
    @ObservationIgnored private var cachedVersion: String?
    /// Los escritorios en modo presentación por lo que ha hecho la app: yabai no dice si los márgenes están quitados
    @ObservationIgnored private var presentationSpaces: Set<Int> = []
    @ObservationIgnored private let poller = Poller()
    @ObservationIgnored private var messageToken = 0
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    /// Lo que se lee en el sondeo y lo que se lee tras una acción no se pisan: gana la lectura más nueva
    @ObservationIgnored private var generation = 0

    init(
        query: any YabaiQuerying, control: any YabaiControlling, settings: AppSettings,
        scriptingAddition: @escaping @MainActor () -> Bool = { ScriptingAddition.isLoaded() },
        version: (@Sendable () async -> String?)? = nil,
        confirm: @escaping @MainActor (String, String, String) -> Bool = { title, detail, button in
            DevConfirmation.confirm(title: title, message: detail, action: button)
        }
    ) {
        self.query = query
        self.control = control
        self.settings = settings
        self.scriptingAddition = scriptingAddition
        self.versionProvider = version
        self.confirm = confirm
    }

    var isRunning: Bool { poller.isRunning }

    /// La scripting addition parece cargada: entonces `space --focus` cambia de escritorio al instante
    var scriptingAdditionLoaded: Bool { scriptingAddition() }

    // MARK: - Ciclo de vida

    /// Con la pestaña Escritorios a la vista se lee cada 2 s; si no, no se consulta nada
    func setVisible(_ visible: Bool) {
        if visible {
            poller.start(interval: Self.pollInterval) { [weak self] generation in
                await self?.read(generation: generation)
            }
            // La versión de yabai, una vez (no cambia mientras corre)
            if cachedVersion == nil, let versionProvider {
                Task { [weak self] in
                    let version = await versionProvider()
                    guard let self, let version, poller.isRunning else { return }
                    cachedVersion = version
                    snapshot.yabaiVersion = version
                }
            }
        } else {
            poller.stop()
            messageTask?.cancel()
            snapshot = DesktopControlSnapshot()
        }
    }

    private func read(generation pollGeneration: Int) async {
        let current = nextGeneration()
        do {
            async let spaces = query.spaces()
            async let windows = query.windows()
            let (allSpaces, allWindows) = try await (spaces, windows)
            // Una lectura que llega cuando el sondeo ya se paró, o que ya tiene otra más nueva detrás, no se publica
            guard poller.isCurrent(pollGeneration), current == generation else { return }
            apply(DesktopWindows.make(spaces: allSpaces, windows: allWindows))
        } catch {
            guard poller.isCurrent(pollGeneration), current == generation, !(error is CancellationError) else { return }
            apply(nil)
        }
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func apply(_ result: (spaceIndex: Int, layout: YabaiLayout?, windows: [DesktopWindow])?) {
        var next = snapshot
        next.spaceIndex = result?.spaceIndex
        next.layout = result?.layout
        next.windows = result?.windows ?? []
        next.floatApps = settings.floatApps
        next.rememberedLayouts = LayoutMemory.decode(settings.rememberedLayouts)
        next.presentationSpaces = presentationSpaces
        next.yabaiVersion = cachedVersion
        next.scriptingAddition = scriptingAddition()
        if next != snapshot { snapshot = next }
    }

    // MARK: - Lo que se pulsa

    /// Ejecuta lo que pide un control. Sin ventana enfocada (o sin escritorio) no hace nada y lo dice
    func press(_ pressed: DesktopControl) {
        // «Recordar en el N» no es una orden de yabai: enciende o apaga que la app recuerde la distribución de este escritorio
        if pressed == .rememberLayout { return toggleRemembering() }
        // «Atajos de skhd» lo atiende la isla (abre Ajustes)
        if pressed == .skhd { return }
        guard let action = pressed.action(snapshot: snapshot) else {
            show(snapshot.spaceIndex == nil ? "yabai no responde" : "No hay ninguna ventana enfocada", isError: true)
            return
        }
        perform(action)
    }

    /// Hace lo que se pide. Devuelve la tarea que queda en marcha (nil si no se intentó), para esperarla
    @discardableResult
    func perform(_ action: YabaiAction) -> Task<Void, Never>? {
        // Lo que necesita la scripting addition y no parece cargada no se intenta: se dice cómo cargarla
        if action.scriptingAddition == .required, !scriptingAddition() {
            show(DesktopControlText.needsScriptingAddition, isError: true)
            return nil
        }
        if case .destroySpace(let index) = action {
            // La isla sigue recibiendo clics con el aviso abierto (`worksWhenModal`): una segunda pregunta encima quitaría dos escritorios
            guard !isAsking else { return nil }
            isAsking = true
            defer { isAsking = false }
            onWillAsk?()
            guard confirm("¿Quitar el escritorio \(index)?", "Sus ventanas pasan al escritorio de al lado. No se puede deshacer.", "Quitar") else { return nil }
        }
        // El escritorio activo al pulsar, no al terminar: lo que se recuerda es de ese
        let spaceIndex = snapshot.spaceIndex
        let previous = actionTask
        let task = Task { [control] in
            // Cada acción espera a la anterior: dos clics seguidos no se cruzan
            await previous?.value
            // El índice de un escritorio que se va a quitar salió de una lectura de hasta 2 s, y el aviso pudo tardar: se vuelve a mirar cuál es
            // el activo, y si ya es otro no se quita nada
            if case .destroySpace(let index) = action, await activeSpaceIndex() != index {
                show("El escritorio activo cambió: no se quitó nada", isError: true)
                return
            }
            do {
                try await control.perform(action)
                remember(action, in: spaceIndex)
                show(action.title, isError: false)
                Logger.yabai.info("Panel de yabai: acción hecha")
            } catch {
                let yabaiError = error as? YabaiError ?? .commandFailed(command: "yabai", stderr: "")
                show(DesktopControlText.message(for: yabaiError, action: action, scriptingAddition: scriptingAddition()), isError: true)
                Logger.yabai.error("Panel de yabai: la acción falló")
            }
            guard action.changesWorkspace else { return }
            onChanged?()
            // Con la pestaña oculta (el cambio de escritorio al instante cierra la isla) no se consulta nada
            if poller.isRunning { await read(generation: poller.generation) }
        }
        actionTask = task
        return task
    }

    private func activeSpaceIndex() async -> Int? {
        (try? await query.spaces())?.first(where: \.hasFocus)?.index
    }

    /// «Recordar en el N»: con él encendido, la distribución de ese escritorio se guarda (y se actualiza cuando la cambias); apagado, se olvida
    private func toggleRemembering() {
        guard let index = snapshot.spaceIndex, let layout = snapshot.layout else {
            show("yabai no responde", isError: true)
            return
        }
        if settings.rememberedLayouts[String(index)] != nil {
            settings.rememberedLayouts.removeValue(forKey: String(index))
            show("Ya no se recuerda la distribución del \(index)", isError: false)
        } else {
            settings.rememberedLayouts[String(index)] = layout.rawValue
            show("Se recordará la distribución del \(index)", isError: false)
        }
        snapshot.rememberedLayouts = LayoutMemory.decode(settings.rememberedLayouts)
    }

    // Lo que la app recuerda para volver a ponerlo cuando yabai se reinicia: la distribución de los escritorios con «Recordar» encendido, y las
    // apps que siempre flotan. Solo lo que pidió el usuario con un clic y salió bien
    private func remember(_ action: YabaiAction, in spaceIndex: Int?) {
        switch action {
        case .setLayout(let layout):
            // Solo si ese escritorio ya se recuerda: elegir una distribución no lo apunta por sí solo
            guard let spaceIndex, settings.rememberedLayouts[String(spaceIndex)] != nil else { return }
            settings.rememberedLayouts[String(spaceIndex)] = layout.rawValue
            snapshot.rememberedLayouts = LayoutMemory.decode(settings.rememberedLayouts)
        case .togglePresentation:
            guard let spaceIndex else { return }
            if !presentationSpaces.insert(spaceIndex).inserted { presentationSpaces.remove(spaceIndex) }
            snapshot.presentationSpaces = presentationSpaces
        case .addFloatRule(let app):
            guard !settings.floatApps.contains(app), settings.floatApps.count < Self.maxFloatApps else { return }
            settings.floatApps.append(app)
            snapshot.floatApps = settings.floatApps
        case .removeFloatRule(let app):
            settings.floatApps.removeAll { $0 == app }
            snapshot.floatApps = settings.floatApps
        // Quitar o mover un escritorio cambia los números de los demás: lo recordado va con ellos
        case .destroySpace(let removed):
            settings.rememberedLayouts = LayoutMemory.encode(LayoutMemory.afterDestroying(removed, in: LayoutMemory.decode(settings.rememberedLayouts)))
        case .moveSpace(let forward):
            guard let spaceIndex else { return }
            settings.rememberedLayouts = LayoutMemory.encode(
                LayoutMemory.afterMoving(spaceIndex, forward: forward, in: LayoutMemory.decode(settings.rememberedLayouts))
            )
        default: break
        }
    }

    /// Más reglas que esto no se guardan: es una lista que se escribe a mano, no un inventario
    static let maxFloatApps = 50

    // MARK: - El mensaje

    private func show(_ text: String, isError: Bool) {
        messageToken += 1
        let token = messageToken
        snapshot.message = DesktopControlMessage(text: text, isError: isError)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration, tolerance: .milliseconds(300))
            guard !Task.isCancelled, let self, messageToken == token else { return }
            snapshot.message = nil
        }
    }

    #if DEBUG
    /// Lo que había antes de la demo
    @ObservationIgnored private var beforeDemo: DesktopControlSnapshot?

    /// Para el snapshot de la isla: cinco ventanas inventadas, con la pila a la vista o no
    func injectDemo(layout: YabaiLayout = .bsp, scriptingAddition: Bool = false, message: DesktopControlMessage? = nil) {
        if beforeDemo == nil { beforeDemo = snapshot }
        let apps: [(String, String)] = [
            ("Safari", "Documentación de yabai"), ("Ghostty", "~/proyectos/tienda"), ("Xcode", "YabaiBar — IslandView.swift"),
            ("Mail", "Bandeja de entrada"), ("Notas", "Ideas"), ("Slack", "equipo-web"),
        ]
        snapshot = DesktopControlSnapshot(
            spaceIndex: 2, layout: layout,
            windows: apps.enumerated().map { index, entry in
                DesktopWindow(
                    id: 100 + index, pid: Int32(900 + index), app: entry.0, title: entry.1, isFocused: index == 1, isFloating: index == 3,
                    isSticky: false, hasParentZoom: false, hasFullscreenZoom: false, stackIndex: index + 1, subLayer: nil
                )
            },
            yabaiVersion: "yabai-v7.1.25", scriptingAddition: scriptingAddition, message: message
        )
    }

    func resetInjected() {
        guard let beforeDemo else { return }
        snapshot = beforeDemo
        self.beforeDemo = nil
    }

    /// Lo que se dibuja en el snapshot: los títulos de tus ventanas de verdad no se guardan en una imagen; solo lo inventado de la demo
    var snapshotForImage: DesktopControlSnapshot {
        guard beforeDemo == nil else { return snapshot }
        var shot = snapshot
        shot.windows = shot.windows.map { window in
            var copy = window
            copy.title = String(repeating: "•", count: 8)
            return copy
        }
        return shot
    }
    #endif
}
