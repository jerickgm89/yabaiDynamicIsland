import Foundation
import Observation
import os

// El módulo Docker: los contenedores, con `docker ps -a`, cada 3 s y solo con la pestaña Desarrollador a la vista y el
// módulo activado en Ajustes. También ejecuta lo que se pulsa en sus filas: parar, reiniciar e iniciar.
@MainActor
@Observable
final class DockerMonitor {
    static let interval: Duration = .seconds(3)
    /// Las consultas se dan por muertas a los 2,5 s; parar un contenedor tarda más (docker espera 10 s a que termine)
    static let queryTimeout: TimeInterval = 2.5
    static let actionTimeout: TimeInterval = 30
    static let candidatePaths = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    /// nil hasta la primera medida
    private(set) var state: DockerState?
    /// El módulo enseña los contenedores parados en vez de los que corren
    var showsStopped = false

    @ObservationIgnored private let queryRunner = CommandRunner(timeout: DockerMonitor.queryTimeout)
    @ObservationIgnored private let actionRunner = CommandRunner(timeout: DockerMonitor.actionTimeout)
    @ObservationIgnored private let poller = Poller()
    @ObservationIgnored private let executable: String?

    init(executable: String? = DockerMonitor.resolvedPath()) {
        self.executable = executable
    }

    var isRunning: Bool { poller.isRunning }

    /// Las apps gráficas no heredan el PATH de la shell: ruta absoluta
    static func resolvedPath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard !poller.isRunning else { return }
        Logger.tools.info("Docker: en marcha")
        poller.start(interval: Self.interval) { [weak self] generation in await self?.sample(generation: generation) }
    }

    func stop() {
        guard poller.isRunning else { return }
        poller.stop()
        state = nil
        showsStopped = false
        Logger.tools.info("Docker: parado")
    }

    func refresh() {
        guard poller.isRunning else { return }
        let generation = poller.generation
        Task { await sample(generation: generation) }
    }

    private func sample(generation: Int) async {
        let measured = await query()
        guard poller.isCurrent(generation) else { return }
        state = measured
        // Sin parados no hay nada que ver en esa vista
        if showsStopped, case .containers(let containers) = measured, !containers.contains(where: { !$0.isAlive }) {
            showsStopped = false
        }
    }

    private func query() async -> DockerState {
        guard let executable else { return .notInstalled }
        do {
            return .containers(DockerParser.parse(try await queryRunner.run(executable, ["ps", "-a", "--size=false", "--format", "{{json .}}"])))
        } catch {
            // El demonio parado, que no contesta o que tarda: Docker no está en marcha. El mensaje de docker lleva rutas del
            // usuario: no va al log
            Logger.tools.info("Docker: no responde")
            return .notRunning
        }
    }

    #if DEBUG
    func sampleOnce() async {
        if !poller.isRunning { state = await query() }
    }
    #endif

    // MARK: - Lo que se pulsa

    func container(withID id: String) -> DockerContainer? {
        guard case .containers(let containers) = state else { return nil }
        return containers.first { $0.id == id }
    }

    /// Los contenedores vivos de un proyecto de Compose
    func aliveContainers(ofProject project: String) -> [DockerContainer] {
        guard case .containers(let containers) = state else { return [] }
        return containers.filter { $0.isAlive && $0.project == project }
    }

    /// `docker <acción> <id>`, o `docker compose -p <proyecto> <acción>` para un proyecto entero. Al terminar, mide ya
    /// y devuelve si salió bien
    @discardableResult
    func run(_ action: RowAction, container id: String? = nil, project: String? = nil) async -> Bool {
        guard let executable, let verb = Self.verb(for: action) else { return false }
        var arguments: [String]
        if let project {
            arguments = ["compose", "-p", project, verb]
        } else if let id {
            arguments = [verb, id]
        } else {
            return false
        }
        defer { refresh() }
        do {
            _ = try await actionRunner.run(executable, arguments)
            return true
        } catch {
            Logger.tools.error("Docker: \(verb, privacy: .public) falló")
            return false
        }
    }

    static func verb(for action: RowAction) -> String? {
        switch action {
        case .stop: "stop"
        case .restart: "restart"
        case .start: "start"
        default: nil
        }
    }
}
