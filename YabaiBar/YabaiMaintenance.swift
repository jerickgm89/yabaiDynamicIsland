import Foundation
import Observation
import os

// Lo que la app hace por yabai fuera de la isla (fase 45): contar cómo está (versión, scripting addition y la chuleta de skhd), volver
// a poner lo que yabai pierde al reiniciarse (la distribución de cada escritorio y las apps que siempre flotan: lo que el usuario eligió con
// un clic) y reiniciarlo, con confirmación. Reiniciar yabai cambia su estado: solo lo hace el usuario con el botón. Lo que dice yabai y lo
// que hay en el skhdrc no van a ningún log.
@MainActor
@Observable
final class YabaiMaintenance {
    private(set) var version: String?
    private(set) var scriptingAddition = false
    /// Los atajos del skhdrc; nil mientras no se ha leído o si no hay archivo
    private(set) var cheatSheet: [SkhdGroup]?
    private(set) var isRestarting = false
    /// El último intento de reiniciar yabai falló
    private(set) var restartFailed = false

    @ObservationIgnored private let client: YabaiClient
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: SpacesStore
    @ObservationIgnored private let confirm: @MainActor (String, String, String) -> Bool
    @ObservationIgnored private var wasFailing = false
    @ObservationIgnored private var sawNotRunning = false
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(
        client: YabaiClient, settings: AppSettings, store: SpacesStore,
        confirm: @escaping @MainActor (String, String, String) -> Bool = { title, detail, button in
            DevConfirmation.confirm(title: title, message: detail, action: button)
        }
    ) {
        self.client = client
        self.settings = settings
        self.store = store
        self.confirm = confirm
    }

    // MARK: - Volver a poner lo que yabai pierde

    /// Cuándo volver a poner lo recordado: solo tras un reinicio de yabai, que se nota porque dejó de responder (el socket) y volvió. Un
    /// error cualquiera que se recupera (un tiempo de espera) no lo es, y al arrancar la app tampoco: yabai tiene lo que el usuario le dejó,
    /// y cambiarlo a mano o con skhd no se pisa
    nonisolated static func restoresAfterRecovery(wasFailing: Bool, failing: Bool, sawNotRunning: Bool) -> Bool {
        wasFailing && !failing && sawNotRunning
    }

    /// Empieza a vigilar a yabai. En los tests no se llama: cambiaría el yabai real
    func start() {
        guard !isStarted else { return }
        isStarted = true
        observe()
    }

    private func observe() {
        let error = withObservationTracking {
            store.lastError
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let failing = error != nil
        if error == .notRunning { sawNotRunning = true }
        if Self.restoresAfterRecovery(wasFailing: wasFailing, failing: failing, sawNotRunning: sawNotRunning) { scheduleRestore() }
        if !failing { sawNotRunning = false }
        wasFailing = failing
    }

    /// Lo llama `YabaiSignals` cuando nota que a yabai le faltan las señales: se reinició sin que fallara ningún refresco
    func yabaiRestarted() {
        scheduleRestore()
    }

    // Un respiro antes de tocar nada: yabai acaba de arrancar y puede no tener aún todos los escritorios
    private func scheduleRestore() {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.restore()
        }
    }

    /// Las acciones que hay que repetir: las distribuciones recordadas que ya no coinciden y las reglas que yabai no tiene. Una sola a la vez
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        var actions = LayoutMemory.reapply(remembered: LayoutMemory.decode(settings.rememberedLayouts), current: store.spaces)
        if !settings.floatApps.isEmpty, let labels = try? await client.ruleLabels() {
            actions += settings.floatApps.filter { !labels.contains(YabaiRules.label(for: $0)) }.map { .addFloatRule(app: $0) }
        }
        guard !actions.isEmpty else { return }
        var done = 0
        for action in actions {
            if Task.isCancelled { break }
            if (try? await client.perform(action)) != nil { done += 1 }
        }
        Logger.yabai.info("yabai: se volvieron a poner \(done, privacy: .public) de \(actions.count, privacy: .public) ajustes recordados")
        if done > 0 { store.requestRefresh() }
    }

    // MARK: - Estado

    /// La versión, la scripting addition y la chuleta de skhd. Se llama al abrir la pestaña de Ajustes. El skhdrc se lee fuera del hilo principal
    func refreshStatus() async {
        scriptingAddition = ScriptingAddition.isLoaded()
        version = try? await client.version()
        cheatSheet = await Task.detached(priority: .utility) { SkhdCheatSheet.read() }.value
    }

    // MARK: - Lo recordado

    func forgetLayout(of space: Int) {
        settings.rememberedLayouts.removeValue(forKey: String(space))
    }

    func forgetAllLayouts() {
        settings.rememberedLayouts = [:]
    }

    /// Quita una app de la lista de las que siempre flotan, y su regla de yabai (si yabai no responde, la regla se va al reiniciarlo)
    func removeFloatApp(_ app: String) {
        settings.floatApps.removeAll { $0 == app }
        Task { [client] in try? await client.perform(.removeFloatRule(app: app)) }
    }

    // MARK: - Reiniciar

    /// «Reiniciar yabai»: con confirmación. Al volver, se vuelven a poner lo recordado y las señales
    func restart() {
        guard !isRestarting,
              confirm("¿Reiniciar yabai?", "Se cierra y se vuelve a abrir en unos segundos. YabaiBar vuelve a poner sus señales y lo que recuerda (distribuciones y apps flotantes).", "Reiniciar")
        else { return }
        isRestarting = true
        restartFailed = false
        Task { [client] in
            do {
                try await client.restartService()
                Logger.yabai.info("yabai: reiniciado desde la app")
            } catch {
                restartFailed = true
                Logger.yabai.error("yabai: no se pudo reiniciar")
            }
            try? await Task.sleep(for: .seconds(3))
            // Se espera a la lectura nueva: con `requestRefresh` (que no espera) `restore` miraría los escritorios de antes del reinicio
            await store.refresh()
            await restore()
            await refreshStatus()
            isRestarting = false
        }
    }
}
