import AppKit
import Observation
import os

// Cuando aparece un escritorio del 1 al 9 sin el atajo «Ir al escritorio N» de Mission Control, la isla no puede
// llevar a él. La primera vez pide permiso con un aviso («Añadir siempre», «Solo este», «Ahora no»); con «Añadir
// siempre», los escritorios nuevos lo reciben solos. También se ofrece al pulsar una tarjeta «Añadir atajo» de la
// isla y desde «Primeros pasos». Al arrancar no pregunta por los que ya faltaban.
@MainActor
final class DesktopShortcutAssistant {
    /// Tras añadirlos: el aviso de la isla cerrada
    var onAdded: (([DesktopShortcuts.Proposal]) -> Void)?

    private let store: SpacesStore
    private let settings: AppSettings
    private let writer: SymbolicHotKeysWriter
    /// Los escritorios vistos desde que arrancó la app; nil hasta la primera lectura. Se acumulan: con varias
    /// pantallas, `store.spaces` solo trae los de la que tiene el foco, y al cambiar de pantalla no son nuevos
    private var known: Set<Int>?
    /// El ajuste en la última lectura, para saber cuándo se activa. Empieza con el guardado: arrancar con «Añadir
    /// siempre» no es activarlo
    private var lastAutoAdd: Bool
    /// Los que el usuario dejó para más tarde con «Ahora no», hasta que la app se reinicia
    private var declined: Set<Int> = []
    /// Preguntando o escribiendo: no se empieza otra vez. Al terminar se vuelve a mirar (ver finished)
    private var busy = false

    private static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    init(store: SpacesStore, settings: AppSettings, writer: SymbolicHotKeysWriter) {
        self.store = store
        self.settings = settings
        self.writer = writer
        lastAutoAdd = settings.autoDesktopShortcuts
        observe()
    }

    /// Desde una tarjeta «Añadir atajo» o desde «Primeros pasos»: pregunta por todos los que faltan (también los que
    /// se dejaron para más tarde), salvo con «Añadir siempre»
    func offer() {
        guard !busy else { return }
        let proposals = missing()
        guard !proposals.isEmpty else {
            // Alguno sigue sin atajo porque su combinación ya la usa otro atajo: se cambia a mano
            let hotkeys = ShortcutFocuser.currentHotkeys()
            if currentDesktops().contains(where: { ShortcutFocuser.shortcut(forDesktop: $0, in: hotkeys) == nil }) {
                NSWorkspace.shared.open(Self.keyboardSettings)
            }
            return
        }
        settings.autoDesktopShortcuts ? add(proposals) : ask(about: proposals)
    }

    // Los escritorios del 1 al 9 que hay ahora. Los espacios a pantalla completa no son escritorios de Mission Control
    private func currentDesktops() -> Set<Int> {
        Set(store.spaces.filter { !$0.isFullscreen }.map(\.index)).intersection(Set(DesktopShortcuts.desktops))
    }

    // Los atajos que faltan en esos escritorios, sin chocar con los de macOS ni con los de YabaiBar
    private func missing() -> [DesktopShortcuts.Proposal] {
        DesktopShortcuts.proposals(for: Array(currentDesktops()), in: ShortcutFocuser.currentHotkeys(), reserved: reserved())
    }

    private func reserved() -> Set<DesktopShortcuts.Combination> {
        Set([settings.toggleShortcut, settings.pomodoroShortcut].compactMap { $0?.combination })
    }

    private func observe() {
        let autoAdd = withObservationTracking {
            _ = store.spaces
            return settings.autoDesktopShortcuts
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        evaluate(autoAdd: autoAdd)
    }

    private func evaluate(autoAdd: Bool) {
        // Con yabai fallando no hay espacios: no es que se hayan quitado. Mientras pregunta o escribe, nada se da
        // por visto: al terminar se vuelve a mirar
        let desktops = currentDesktops()
        guard !busy, store.lastError == nil, !store.spaces.isEmpty else { return }
        let isFirstLook = known == nil
        let newDesktops = desktops.subtracting(known ?? [])
        let autoAddTurnedOn = autoAdd && !lastAutoAdd
        known = (known ?? []).union(desktops)
        lastAutoAdd = autoAdd
        // Los espacios cambian a menudo (apps que se abren y se cierran): solo se miran los atajos si hay
        // escritorios nuevos, al arrancar o al activar «Añadir siempre»
        guard isFirstLook || !newDesktops.isEmpty || autoAddTurnedOn else { return }
        let proposals = missing()
        let decision = DesktopShortcuts.decision(
            autoAdd: autoAdd, autoAddTurnedOn: autoAddTurnedOn, isFirstLook: isFirstLook, newDesktops: newDesktops,
            missing: proposals.map(\.desktop), declined: declined
        )
        switch decision {
        case .nothing: break
        case .add(let targets): add(proposals.filter { targets.contains($0.desktop) })
        case .ask(let targets): ask(about: proposals.filter { targets.contains($0.desktop) })
        }
    }

    // Al terminar de preguntar o de escribir: lo que cambió mientras tanto (otro escritorio nuevo) se mira ahora
    private func finished() {
        busy = false
        evaluate(autoAdd: settings.autoDesktopShortcuts)
    }

    private func ask(about proposals: [DesktopShortcuts.Proposal]) {
        busy = true
        let desktops = DesktopShortcuts.list(proposals.map { String($0.desktop) })
        let labels = DesktopShortcuts.list(proposals.map(\.label))
        let one = proposals.count == 1
        let alert = NSAlert()
        alert.messageText = one ? "El escritorio \(desktops) no tiene atajo" : "Los escritorios \(desktops) no tienen atajo"
        alert.informativeText = """
            La isla te lleva a cada escritorio pulsando su atajo «Ir al escritorio» de Mission Control. \
            ¿Añado \(labels) en Ajustes › Teclado › Atajos de teclado?

            Con «Añadir siempre», los escritorios que crees después tendrán su atajo sin preguntar. YabaiBar solo \
            añade los que faltan y antes guarda una copia de tus atajos.
            """
        alert.addButton(withTitle: "Añadir siempre")
        alert.addButton(withTitle: one ? "Solo este" : "Solo estos")
        alert.addButton(withTitle: "Ahora no")
        let response = runModal(alert)
        Logger.app.info("Atajos de escritorio \(labels, privacy: .public): respuesta \(response.rawValue)")
        switch response {
        case .alertFirstButtonReturn:
            add(proposals)
            // Elegido aquí, «Añadir siempre» es para los escritorios que vengan: no añade de golpe los que ya faltaban
            lastAutoAdd = true
            settings.autoDesktopShortcuts = true
        case .alertSecondButtonReturn:
            add(proposals)
        default:
            declined.formUnion(proposals.map(\.desktop))
            finished()
        }
    }

    private func add(_ proposals: [DesktopShortcuts.Proposal]) {
        busy = true
        let reserved = reserved()
        Task {
            defer { finished() }
            do throws(SymbolicHotKeysWriter.WriteError) {
                let written = try await writer.add(proposals, reserved: reserved)
                if !written.isEmpty { onAdded?(written) }
            } catch {
                Logger.app.error("Atajos de escritorio: \(String(describing: error), privacy: .public)")
                report(error, labels: DesktopShortcuts.list(proposals.map(\.label)))
            }
        }
    }

    private func report(_ error: SymbolicHotKeysWriter.WriteError, labels: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch error {
        case .noBackup(let reason):
            alert.messageText = "No se pudo añadir \(labels)"
            alert.informativeText = "No se pudo guardar antes una copia de tus atajos (\(reason)), así que no se ha cambiado nada."
        case .notSaved:
            alert.messageText = "No se pudo añadir \(labels)"
            alert.informativeText = "macOS no guardó el cambio. Puedes añadirlo en Ajustes › Teclado › Atajos de teclado › Mission Control."
        case .notApplied:
            alert.messageText = "Guardado: \(labels)"
            alert.informativeText = "macOS aún no lo aplica: lo hará al cerrar sesión o al abrir Ajustes › Teclado › Atajos de teclado."
        }
        alert.addButton(withTitle: "Abrir Teclado")
        alert.addButton(withTitle: "Cerrar")
        if runModal(alert) == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.keyboardSettings) }
    }

    // La app no sale en el Dock ni en ⌘⇥: el aviso va por encima de las ventanas normales, para que no se pierda
    // detrás de otra app, y la app se activa para que reciba el teclado. Si ya estaba activa («Primeros pasos»),
    // se queda así al cerrarlo
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let wasActive = NSApp.isActive
        alert.window.level = .floating
        NSApp.activate()
        let response = alert.runModal()
        if !wasActive { NSApp.deactivate() }
        return response
    }
}
