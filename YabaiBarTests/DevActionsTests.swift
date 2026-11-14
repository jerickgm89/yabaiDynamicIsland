import Foundation
import Testing
@testable import YabaiBar

// Lo que hacen los botones de las filas, con procesos y programas de verdad: un servidor de Python que escucha en un puerto, y
// un `docker` falso que apunta lo que se le pide. La pregunta antes de cerrar o parar la responde el propio test
@MainActor
struct DevActionsTests {
    /// Las preguntas que salieron, con el botón de confirmar de cada una
    final class Asked {
        var actions: [String] = []
        var titles: [String] = []
    }

    private func make(
        docker: DockerMonitor = DockerMonitor(executable: nil), asked: Asked = Asked(), answers: [Bool] = [true]
    ) throws -> DevTools {
        let defaults = UserDefaults(suiteName: "devactions-tests-\(UUID().uuidString)")!
        var remaining = answers
        let settings = AppSettings(defaults: defaults)
        return DevTools(
            system: SystemMonitor(), ports: PortsMonitor(), docker: docker, claude: try ClaudeTestSupport.sessions(),
            git: GitMonitor(git: nil, gh: nil, settings: settings), notices: NoticeLog(), settings: settings
        ) { title, _, action in
            asked.titles.append(title)
            asked.actions.append(action)
            return remaining.isEmpty ? false : remaining.removeFirst()
        }
    }

    // MARK: Puertos

    // Un servidor de Python que escucha en un puerto y, si se pide, ignora SIGTERM
    private func spawnServer(ignoringTerminate: Bool = false) throws -> (process: Process, port: Int) {
        let script = """
            import signal, socket, time
            \(ignoringTerminate ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "")
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            s.listen(1)
            print(s.getsockname()[1], flush=True)
            time.sleep(120)
            """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let port = try #require(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        return (process, port)
    }

    // Con la pestaña a la vista, espera a que Puertos vea ese servidor y devuelve su fila
    private func watch(_ tools: DevTools, pid: Int32) async throws -> PortListener {
        tools.setVisibleTab(.developer)
        var waited = 0
        while waited < 60 {
            if let listener = tools.ports.listeners?.first(where: { $0.pid == pid }) { return listener }
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        throw Failure("Puertos no vio el servidor")
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // Se le pide que termine: pregunta, y el proceso acaba. Justo después de pulsar, la isla se cierra y los módulos olvidan
    // lo que tenían: no importa, porque el proceso se resolvió antes
    @Test func closingAPortAsksAndTerminatesTheProcess() async throws {
        let server = try spawnServer()
        defer { if server.process.isRunning { server.process.terminate() } }
        let asked = Asked()
        let tools = try make(asked: asked)
        let listener = try await watch(tools, pid: server.process.processIdentifier)
        let task = tools.perform(ModuleControl(module: .ports, row: listener.id, action: .close))
        tools.setVisibleTab(nil)
        #expect(tools.ports.listeners == nil)
        await task?.value
        server.process.waitUntilExit()
        #expect(server.process.terminationReason == .uncaughtSignal && server.process.terminationStatus == SIGTERM)
        #expect(asked.actions == ["Cerrar proceso"])
        #expect(asked.titles.first?.contains(String(server.port)) == true)
    }

    // Con la pregunta abierta la isla sigue viva: volver a pulsar «cerrar» no apila otra pregunta encima
    @Test func closingWhileAskingDoesNotStackAnotherQuestion() async throws {
        let server = try spawnServer()
        defer { server.process.terminate() }
        final class Holder {
            var tools: DevTools?
            var control: ModuleControl?
            var asked = 0
            var nested: Task<Void, Never>?
        }
        let holder = Holder()
        let defaults = UserDefaults(suiteName: "devactions-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let tools = DevTools(
            system: SystemMonitor(), ports: PortsMonitor(), docker: DockerMonitor(executable: nil),
            claude: try ClaudeTestSupport.sessions(), git: GitMonitor(git: nil, gh: nil, settings: settings), notices: NoticeLog(), settings: settings
        ) { _, _, _ in
            holder.asked += 1
            if let control = holder.control { holder.nested = holder.tools?.perform(control) }
            return false
        }
        holder.tools = tools
        let listener = try await watch(tools, pid: server.process.processIdentifier)
        let control = ModuleControl(module: .ports, row: listener.id, action: .close)
        holder.control = control
        await tools.perform(control)?.value
        #expect(holder.asked == 1 && holder.nested == nil)
        // Ya sin pregunta abierta, vuelve a preguntar
        await tools.perform(control)?.value
        #expect(holder.asked == 2)
        tools.setVisibleTab(nil)
    }

    @Test func decliningLeavesTheProcessAlone() async throws {
        let server = try spawnServer()
        defer { server.process.terminate() }
        let asked = Asked()
        let tools = try make(asked: asked, answers: [false])
        let listener = try await watch(tools, pid: server.process.processIdentifier)
        await tools.perform(ModuleControl(module: .ports, row: listener.id, action: .close))?.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.process.isRunning)
        #expect(asked.actions == ["Cerrar proceso"])
        tools.setVisibleTab(nil)
    }

    // Un proceso que ignora SIGTERM: a los 3 s se ofrece forzarlo, con otra pregunta, y entonces se le manda SIGKILL
    @Test func aProcessThatIgnoresTerminateIsForcedAfterAskingAgain() async throws {
        let server = try spawnServer(ignoringTerminate: true)
        defer { if server.process.isRunning { server.process.terminate() } }
        let asked = Asked()
        let tools = try make(asked: asked, answers: [true, true])
        let listener = try await watch(tools, pid: server.process.processIdentifier)
        await tools.perform(ModuleControl(module: .ports, row: listener.id, action: .close))?.value
        server.process.waitUntilExit()
        #expect(server.process.terminationStatus == SIGKILL)
        #expect(asked.actions == ["Cerrar proceso", "Forzar"])
        tools.setVisibleTab(nil)
    }

    @Test func refusingToForceLeavesItRunning() async throws {
        let server = try spawnServer(ignoringTerminate: true)
        defer { server.process.terminate() }
        let asked = Asked()
        let tools = try make(asked: asked, answers: [true, false])
        let listener = try await watch(tools, pid: server.process.processIdentifier)
        await tools.perform(ModuleControl(module: .ports, row: listener.id, action: .close))?.value
        #expect(server.process.isRunning)
        #expect(asked.actions == ["Cerrar proceso", "Forzar"])
        tools.setVisibleTab(nil)
        // El proceso ignora SIGTERM: para no dejarlo, se le manda SIGKILL
        kill(server.process.processIdentifier, SIGKILL)
    }

    @Test func aRowThatIsNotThereAnymoreDoesNothing() async throws {
        let asked = Asked()
        let tools = try make(asked: asked)
        let task = tools.perform(ModuleControl(module: .ports, row: "999999:1", action: .close))
        #expect(task == nil && asked.actions.isEmpty)
    }

    // El mismo reparto que la fila: nunca el pid 1, ni uno mismo, ni otro usuario, ni los protegidos
    @Test func whatCannotBeClosedIsRefusedEvenIfAskedFor() {
        let own = getuid()
        func can(_ command: String, pid: Int32 = 500, uid: UInt32? = nil) -> Bool {
            PortRows.canClose(PortListener(pid: pid, command: command, uid: uid ?? own, port: 3000), ownUID: own, ownPID: getpid())
        }
        #expect(can("node"))
        #expect(!can("node", pid: getpid()))
        #expect(!can("node", pid: 1))
        #expect(!can("node", uid: own + 1))
        #expect(!can("com.docker.backend"))
    }

    // MARK: Docker

    private func fakeDocker(log: String) throws -> DockerMonitor {
        let fixture = Fixture.directory.appending(path: "docker-ps-compose.jsonl").path(percentEncoded: false)
        let body = "case \"$1\" in ps) cat '\(fixture)';; *) echo \"$@\" >> '\(log)';; esac"
        return DockerMonitor(executable: try FakeYabai.make(body))
    }

    private func tempLog() -> String {
        FileManager.default.temporaryDirectory.appending(path: "docker-actions-\(UUID().uuidString)").path(percentEncoded: false)
    }

    private func lines(of log: String) -> [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func stoppingAContainerAsksFirst() async throws {
        let log = tempLog()
        let docker = try fakeDocker(log: log)
        await docker.sampleOnce()
        let asked = Asked()
        let tools = try make(docker: docker, asked: asked)
        await tools.perform(ModuleControl(module: .docker, row: "container:1d5e8f7a6b09", action: .stop))?.value
        #expect(asked.actions == ["Parar"])
        #expect(asked.titles == ["¿Parar el contenedor «pg-dev»?"])
        #expect(lines(of: log) == ["stop 1d5e8f7a6b09"])
    }

    @Test func decliningDoesNotStopTheContainer() async throws {
        let log = tempLog()
        let docker = try fakeDocker(log: log)
        await docker.sampleOnce()
        let tools = try make(docker: docker, answers: [false])
        await tools.perform(ModuleControl(module: .docker, row: "container:1d5e8f7a6b09", action: .stop))?.value
        #expect(lines(of: log).isEmpty)
    }

    // Un proyecto de Compose se para entero, y la pregunta dice cuántos contenedores son
    @Test func stoppingAProjectStopsAllItsContainers() async throws {
        let log = tempLog()
        let docker = try fakeDocker(log: log)
        await docker.sampleOnce()
        let asked = Asked()
        let tools = try make(docker: docker, asked: asked)
        await tools.perform(ModuleControl(module: .docker, row: "project:shop", action: .stop))?.value
        #expect(asked.titles == ["¿Parar el proyecto «shop»?"])
        #expect(lines(of: log) == ["compose -p shop stop"])
    }

    // Reiniciar e iniciar no quitan nada: no preguntan
    @Test func restartAndStartDoNotAsk() async throws {
        let log = tempLog()
        let docker = try fakeDocker(log: log)
        await docker.sampleOnce()
        let asked = Asked()
        let tools = try make(docker: docker, asked: asked)
        await tools.perform(ModuleControl(module: .docker, row: "container:1d5e8f7a6b09", action: .restart))?.value
        await tools.perform(ModuleControl(module: .docker, row: "container:b9c8d7e6f5a4", action: .start))?.value
        await tools.perform(ModuleControl(module: .docker, row: "project:blog", action: .restart))?.value
        #expect(asked.actions.isEmpty)
        #expect(lines(of: log) == ["restart 1d5e8f7a6b09", "start b9c8d7e6f5a4", "compose -p blog restart"])
    }

    @Test func theStoppedViewTogglesWithoutRunningAnything() async throws {
        let log = tempLog()
        let docker = try fakeDocker(log: log)
        let tools = try make(docker: docker)
        tools.perform(ModuleControl(module: .docker, row: DockerRows.stoppedToggleID, action: .showStopped))
        #expect(docker.showsStopped)
        tools.perform(ModuleControl(module: .docker, row: DockerRows.backID, action: .hideStopped))
        #expect(!docker.showsStopped)
        #expect(lines(of: log).isEmpty)
    }

    // El aviso se arma con lo que se sabía al pulsar, aunque la isla se cierre y el módulo olvide los contenedores
    @Test func theQuestionSurvivesTheIslandClosing() async throws {
        let log = tempLog()
        let docker = try fakeDocker(log: log)
        let asked = Asked()
        let tools = try make(docker: docker, asked: asked)
        tools.setVisibleTab(.developer)
        var waited = 0
        while docker.state == nil && waited < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let task = tools.perform(ModuleControl(module: .docker, row: "container:1d5e8f7a6b09", action: .stop))
        tools.setVisibleTab(nil)
        #expect(docker.state == nil)
        await task?.value
        #expect(asked.titles == ["¿Parar el contenedor «pg-dev»?"])
        #expect(lines(of: log) == ["stop 1d5e8f7a6b09"])
    }
}
