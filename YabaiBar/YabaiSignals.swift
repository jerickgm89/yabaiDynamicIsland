import Foundation
import Observation
import os

// Las señales de yabai que refrescan la isla al crear, cerrar o minimizar ventanas y al cambiar los espacios o las
// pantallas. YabaiBar las añade sola con `yabai -m signal --add`, sin tocar el yabairc. Las señales añadidas así se
// pierden cuando yabai se reinicia: se vuelven a añadir cuando yabai responde tras un error y, como mucho una vez por
// minuto, si al comprobarlas faltan (también si el primer intento falló). Añadir con la misma etiqueta sustituye a
// la anterior, así que convive con quien ya las tenga en su yabairc.
@MainActor
final class YabaiSignals {
    nonisolated static let events = [
        "window_created", "window_destroyed", "window_minimized", "window_deminimized",
        "space_created", "space_destroyed", "display_added", "display_removed", "display_changed",
    ]
    /// La misma notificación Darwin que escucha AppDelegate
    nonisolated static let action = "notifyutil -p \(AppDelegate.refreshNotificationName)"
    static let checkInterval: Duration = .seconds(60)

    nonisolated static func label(for event: String) -> String { "yb_\(event)" }

    nonisolated static func addArguments(for event: String) -> [String] {
        ["--add", "event=\(event)", "label=\(label(for: event))", "action=\(action)"]
    }

    nonisolated static func removeArguments(for event: String) -> [String] {
        ["--remove", label(for: event)]
    }

    /// Si a yabai le falta alguna de las señales de YabaiBar
    nonisolated static func isMissing(from labels: [String]) -> Bool {
        let present = Set(labels)
        return !events.allSatisfy { present.contains(label(for: $0)) }
    }

    /// Qué hacer cuando cambia el ajuste o el estado de yabai: true, añadirlas; false, quitarlas; nil, nada.
    /// Se añaden si el ajuste está activado, yabai responde y aún no están (o yabai acaba de volver de un error,
    /// que quizá fue un reinicio); se quitan al apagar el ajuste. Mientras yabai falla no se intenta
    nonisolated static func change(enabled: Bool, failing: Bool, wasFailing: Bool, installed: Bool) -> Bool? {
        if enabled {
            let recovered = wasFailing && !failing
            return !failing && (!installed || recovered) ? true : nil
        }
        return installed ? false : nil
    }

    private let client: YabaiClient
    private let settings: AppSettings
    private let store: SpacesStore
    /// Si deberían estar añadidas (se pidió añadirlas y no falló)
    private var installed = false
    private var wasFailing = false
    private var lastCheck: ContinuousClock.Instant?
    private var task: Task<Void, Never>?

    init(client: YabaiClient, settings: AppSettings, store: SpacesStore) {
        self.client = client
        self.settings = settings
        self.store = store
        observe()
    }

    /// Lo llama AppDelegate con cada aviso de macOS. Comprueba, como mucho una vez por minuto, que yabai tiene las
    /// señales: si se reinició sin que fallara ningún refresco, o si el primer intento falló, faltarán
    func verify() {
        guard settings.autoYabaiSignals else { return }
        let now = ContinuousClock.now
        if let lastCheck, now - lastCheck < Self.checkInterval { return }
        lastCheck = now
        Task { [client] in
            guard let labels = try? await client.signalLabels(), Self.isMissing(from: labels),
                  settings.autoYabaiSignals else { return }
            Logger.yabai.info("Señales de yabai: faltan, se vuelven a añadir")
            run(add: true)
        }
    }

    private func observe() {
        let (enabled, failing) = withObservationTracking {
            (settings.autoYabaiSignals, store.lastError != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let change = Self.change(enabled: enabled, failing: failing, wasFailing: wasFailing, installed: installed)
        wasFailing = failing
        if let change { run(add: change) }
    }

    // Cada petición espera a que termine la anterior (cancelada), para que un --remove a medias no se cruce con el
    // --add del mismo evento
    private func run(add: Bool) {
        let previous = task
        previous?.cancel()
        installed = add
        if add { lastCheck = .now }
        task = Task { [client] in
            await previous?.value
            guard !Task.isCancelled else { return }
            if add {
                do {
                    for event in Self.events {
                        try Task.checkCancellation()
                        try await client.signal(Self.addArguments(for: event))
                    }
                    Logger.yabai.info("Señales de yabai: añadidas")
                } catch {
                    // Si otra petición la sustituyó, el estado es el de esa
                    guard !Task.isCancelled else { return }
                    // yabai no responde: se vuelven a intentar cuando responda o al comprobarlas
                    installed = false
                    Logger.yabai.error("Señales de yabai: \(String(describing: error), privacy: .public)")
                }
            } else {
                // Cada una por su cuenta: una que ya no esté no impide quitar las demás
                var failures = 0
                for event in Self.events where !Task.isCancelled {
                    do { try await client.signal(Self.removeArguments(for: event)) } catch { failures += 1 }
                }
                Logger.yabai.info("Señales de yabai: quitadas (\(failures) no estaban)")
            }
        }
    }
}
