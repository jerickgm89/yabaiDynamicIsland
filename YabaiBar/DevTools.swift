import AppKit
import Foundation
import Observation
import os

// Arranca y para las consultas periódicas de los módulos de la pestaña Desarrollador, y ejecuta lo que se pulsa en
// ellos. Nada consulta con la isla cerrada ni con otra pestaña a la vista: IslandController dice qué pestaña se ve
// (`setVisibleTab`) y cada módulo corre solo mientras es la suya. Claude Code es la excepción: mientras una sesión espera tu
// respuesta lee sus archivos aunque la isla esté cerrada, para que el punto naranja no se quede. Los módulos nuevos se suman aquí.
@MainActor
final class DevTools {
    let system: SystemMonitor
    let ports: PortsMonitor
    let docker: DockerMonitor
    let claude: ClaudeSessions
    let git: GitMonitor
    /// Los últimos avisos de la isla cerrada, para el módulo Avisos
    let notices: NoticeLog
    private let settings: AppSettings
    private let confirm: @MainActor (_ title: String, _ message: String, _ action: String) -> Bool
    private var visibleTab: IslandTab?
    /// Hay una pregunta abierta. El aviso es modal pero la isla sigue viva (`worksWhenModal`): sin esto, volver a pulsar
    /// «cerrar» o «parar» apilaría otra pregunta encima
    private var isAsking = false

    /// Lo que se espera a que un proceso termine tras pedírselo, antes de ofrecer forzarlo
    static let closeGrace: Duration = .seconds(3)

    /// `confirm` es la pregunta antes de cerrar o parar algo; en los tests, una respuesta ya dada
    init(
        system: SystemMonitor, ports: PortsMonitor, docker: DockerMonitor, claude: ClaudeSessions, git: GitMonitor,
        notices: NoticeLog, settings: AppSettings,
        confirm: @escaping @MainActor (_ title: String, _ message: String, _ action: String) -> Bool = {
            DevConfirmation.confirm(title: $0, message: $1, action: $2)
        }
    ) {
        self.system = system
        self.ports = ports
        self.docker = docker
        self.claude = claude
        self.git = git
        self.notices = notices
        self.settings = settings
        self.confirm = confirm
        observeSettings()
    }

    /// La pestaña que se ve con la isla abierta; nil con la isla cerrada
    func setVisibleTab(_ tab: IslandTab?) {
        visibleTab = tab
        applyVisibility()
    }

    /// Algún módulo está consultando ahora
    var isPolling: Bool { system.isRunning || ports.isRunning || docker.isRunning || claude.isRunning || git.isRunning }

    private func applyVisibility() {
        // Claude Code sigue leyendo sus archivos aunque la pestaña no se vea mientras alguna sesión espera una respuesta
        claude.setVisible(visibleTab == .developer)
        // Git vigila con la isla cerrada, por eventos; con la pestaña a la vista, además, consulta GitHub cada minuto
        git.setVisible(visibleTab == .developer)
        guard visibleTab == .developer else {
            system.stop()
            ports.stop()
            docker.stop()
            return
        }
        system.start()
        ports.start()
        // Docker apagado en Ajustes: el módulo no se ve y no se consulta
        if settings.showDocker { docker.start() } else { docker.stop() }
    }

    // Si Docker se apaga o se enciende en Ajustes con la pestaña a la vista, el módulo empieza o deja de consultar
    private func observeSettings() {
        withObservationTracking {
            _ = settings.showDocker
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyVisibility()
                self?.observeSettings()
            }
        }
    }

    #if DEBUG
    /// Para el snapshot de la isla: una medida de cada módulo sin dejarlos en marcha
    func sampleOnce() async {
        await system.sampleOnce()
        await ports.sampleOnce()
        if settings.showDocker { await docker.sampleOnce() }
        claude.connection.refresh()
        await claude.sampleOnce()
    }
    #endif

    // MARK: - Lo que enseñan los módulos

    /// Las filas de Puertos y Docker. Se lee desde un `withObservationTracking`, así que cada cambio de las medidas
    /// vuelve a pedirlas
    func rowsContent() -> [ModuleID: ModuleRowsContent] {
        var content: [ModuleID: ModuleRowsContent] = [:]
        // Con el módulo Docker a la vista, los puertos que abre su servidor son los de los contenedores y salen allí
        content[.ports] = PortRows.content(
            of: ports.listeners, ownUID: getuid(), ownPID: getpid(), hidingDockerBackend: settings.showDocker
        )
        if settings.showDocker {
            content[.docker] = DockerRows.content(of: docker.state, showStopped: docker.showsStopped)
        }
        content[.claude] = ClaudeRows.content(of: claude.sessions, connected: claude.connection.status.map { $0 == .connected })
        if settings.showGit {
            content[.git] = GitRows.content(of: git.repos, github: git.github, gitAvailable: git.gitAvailable)
        }
        content[.notices] = NoticeRows.content(of: notices.entries, time: Self.time)
        return content
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// La hora de un aviso, «14:32», siempre de 24 h (la de 12 h con «PM» ocupa más y recortaba el detalle). Fija: no se queda vieja
    /// entre medidas, como un «hace 5 min»
    private static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // MARK: - Lo que se pulsa

    /// Los botones de las filas. Los que quitan o paran algo preguntan antes. A lo que se refiere el botón (el proceso, el
    /// contenedor) se resuelve aquí mismo, antes de que nada espere: el controlador cierra la isla justo después, y al
    /// cerrarse los módulos dejan de medir y olvidan lo que tenían. Devuelve la tarea que queda en marcha, para esperarla
    @discardableResult
    func perform(_ control: ModuleControl) -> Task<Void, Never>? {
        Logger.tools.info("Módulo \(control.module.rawValue, privacy: .public): \(control.action.rawValue, privacy: .public)")
        if isAsking, control.action.isDestructive { return nil }
        switch control.module {
        case .ports: return performPort(control)
        case .docker: return performDocker(control)
        case .claude: return performClaude(control)
        case .git: return performGit(control)
        case .notices: return performNotice(control)
        default: return nil
        }
    }

    // MARK: Puertos

    private func performPort(_ control: ModuleControl) -> Task<Void, Never>? {
        guard let listener = ports.listener(withID: control.row) else { return nil }
        switch control.action {
        case .open:
            if let url = listener.url { NSWorkspace.shared.open(url) }
        case .copy:
            if let url = listener.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        case .close:
            // El botón solo está en lo que se puede cerrar; esto es por si se pide igualmente
            guard PortRows.canClose(listener, ownUID: getuid(), ownPID: getpid()) else {
                Logger.tools.error("Puertos: ese proceso no se puede cerrar desde aquí")
                return nil
            }
            return Task { await close(listener) }
        default:
            break
        }
        return nil
    }

    // Pregunta, manda SIGTERM y, si a los 3 s sigue escuchando, ofrece forzarlo con SIGKILL, con otra pregunta. Justo antes
    // de cada señal se vuelve a mirar que sea el mismo proceso: entre que el usuario lo vio y confirmó pudo terminar y su pid,
    // ser de otro
    private func close(_ listener: PortListener) async {
        let asked = ask(
            "¿Cerrar «\(listener.command)» en el puerto \(listener.port)?",
            "Se le pedirá al proceso \(listener.pid) que termine. Lo que no haya guardado se puede perder.",
            "Cerrar proceso"
        )
        guard asked, await ports.isStillListening(listener) else { return }
        guard kill(listener.pid, SIGTERM) == 0 else {
            Logger.tools.error("Puertos: no se pudo mandar SIGTERM (errno \(errno))")
            return
        }
        // Cada segundo se mira si ya dejó de escuchar
        let checks = Int(Self.closeGrace.components.seconds)
        for _ in 0..<checks {
            try? await Task.sleep(for: .seconds(1))
            if !(await ports.isStillListening(listener)) {
                ports.refresh()
                return
            }
        }
        let forced = ask(
            "«\(listener.command)» sigue abierto",
            "Sigue escuchando en el puerto \(listener.port) tras pedirle que termine. ¿Lo fuerzo? No tendrá ocasión de guardar nada.",
            "Forzar"
        )
        if forced, await ports.isStillListening(listener) { kill(listener.pid, SIGKILL) }
        ports.refresh()
    }

    private func ask(_ title: String, _ message: String, _ action: String) -> Bool {
        isAsking = true
        defer { isAsking = false }
        return confirm(title, message, action)
    }

    // MARK: Claude Code

    // Un clic en una sesión lleva a su app. «Conectar» lo atiende el controlador: abre Ajustes
    private func performClaude(_ control: ModuleControl) -> Task<Void, Never>? {
        if control.action == .activate, let id = ClaudeRows.sessionID(ofRow: control.row) { claude.activate(sessionID: id) }
        return nil
    }

    // MARK: Git

    // Solo informa: un clic en un repositorio abre su página de GitHub. La dirección se arma con el dueño y el nombre que se
    // sacaron de la remota (solo github.com), nunca se abre una remota tal cual
    private func performGit(_ control: ModuleControl) -> Task<Void, Never>? {
        if control.action == .open, let url = git.repo(withID: control.row)?.remote?.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: Avisos

    // Un clic en un aviso lleva a su origen: la app de la terminal (solo si ya está abierta), la sesión de Claude o la página del
    // repositorio
    private func performNotice(_ control: ModuleControl) -> Task<Void, Never>? {
        guard let entry = notices.entry(withID: control.row) else { return nil }
        switch entry.origin {
        case .terminal(let bundleID):
            if let bundleID { TerminalNotices.activate(bundleID: bundleID) }
        case .claude(let sessionID):
            claude.activate(sessionID: sessionID)
        case .git(let name):
            if let url = git.repos.first(where: { $0.name == name })?.remote?.url { NSWorkspace.shared.open(url) }
        case .calendar:
            CalendarStore.openCalendarApp()
        }
        return nil
    }

    // MARK: Docker

    private func performDocker(_ control: ModuleControl) -> Task<Void, Never>? {
        let target = DockerRows.target(ofRow: control.row)
        switch control.action {
        case .showStopped:
            docker.showsStopped = true
        case .hideStopped:
            docker.showsStopped = false
        case .stop:
            // El texto de la pregunta se arma ya, con lo que se sabe ahora
            let title: String
            let message: String
            if let project = target.project {
                let count = docker.aliveContainers(ofProject: project).count
                title = "¿Parar el proyecto «\(project)»?"
                message = "Se pararán sus \(count) contenedores (docker compose stop). Puedes volver a iniciarlos desde Docker."
            } else if let id = target.container, let container = docker.container(withID: id) {
                title = "¿Parar el contenedor «\(container.name)»?"
                message = "Se ejecutará docker stop. Puedes volver a iniciarlo desde la isla."
            } else {
                return nil
            }
            return Task {
                guard ask(title, message, "Parar") else { return }
                await docker.run(.stop, container: target.container, project: target.project)
            }
        case .restart, .start:
            return Task { await docker.run(control.action, container: target.container, project: target.project) }
        default:
            break
        }
        return nil
    }
}
