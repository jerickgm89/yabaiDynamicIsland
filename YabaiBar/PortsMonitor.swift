import Foundation
import Observation
import os

// El módulo Puertos: los procesos que escuchan en un puerto TCP, con `lsof`, cada 3 s y solo con la pestaña Desarrollador
// a la vista (DevTools lo arranca y lo para).
@MainActor
@Observable
final class PortsMonitor {
    static let interval: Duration = .seconds(3)
    static let lsofPath = "/usr/sbin/lsof"
    private static let arguments = ["+c", "0", "-w", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnuL"]

    /// nil hasta la primera medida
    private(set) var listeners: [PortListener]?

    @ObservationIgnored private let runner: CommandRunner
    @ObservationIgnored private let poller = Poller()

    init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    var isRunning: Bool { poller.isRunning }

    func start() {
        guard !poller.isRunning else { return }
        Logger.tools.info("Puertos: en marcha")
        poller.start(interval: Self.interval) { [weak self] generation in await self?.sample(generation: generation) }
    }

    func stop() {
        guard poller.isRunning else { return }
        poller.stop()
        listeners = nil
        Logger.tools.info("Puertos: parado")
    }

    /// Mide ahora, sin esperar a la siguiente: tras cerrar un proceso
    func refresh() {
        guard poller.isRunning else { return }
        let generation = poller.generation
        Task { await sample(generation: generation) }
    }

    private func sample(generation: Int) async {
        let found = await Self.listening(runner: runner)
        // Si mientras tanto se paró o se volvió a arrancar, esta medida ya no vale
        guard poller.isCurrent(generation), let found else { return }
        listeners = found
    }

    /// Los puertos que escuchan ahora. nil si `lsof` falla de verdad: sin nada escuchando sale con 1 y sin mensaje
    static func listening(runner: CommandRunner) async -> [PortListener]? {
        do {
            return LsofParser.parse(try await runner.run(lsofPath, arguments))
        } catch CommandRunner.Failure.failed(_, 1, "") {
            return []
        } catch {
            // El mensaje de lsof puede llevar rutas: no va al log
            Logger.tools.info("Puertos: lsof falló")
            return nil
        }
    }

    /// El proceso sigue escuchando en ese puerto con ese pid y ese nombre. Se mira justo antes de mandarle una señal: entre
    /// que el usuario lo vio y confirmó pudo terminar y su pid, ser de otro proceso
    func isStillListening(_ listener: PortListener) async -> Bool {
        let found = await Self.listening(runner: runner) ?? []
        return found.contains { $0.pid == listener.pid && $0.port == listener.port && $0.command == listener.command }
    }

    #if DEBUG
    func sampleOnce() async {
        if !poller.isRunning, let found = await Self.listening(runner: runner) { listeners = found }
    }
    #endif

    func listener(withID id: String) -> PortListener? {
        listeners?.first { $0.id == id }
    }
}
