import Foundation
import Testing
@testable import YabaiBar

// docker-ps.jsonl es la salida real de `docker ps -a --format '{{json .}}'` de esta máquina, con los nombres de los
// proyectos y las rutas cambiados: un contenedor parado y dos que corren, de dos proyectos de Compose distintos.
// docker-ps-compose.jsonl está escrito a mano con el mismo formato, para lo que la máquina no tenía: un proyecto con
// tres contenedores, uno parado de un proyecto y uno recién creado
struct DockerParserTests {
    @Test func readsTheRealOutput() throws {
        let containers = DockerParser.parse(try Fixture.text("docker-ps", extension: "jsonl"))
        #expect(containers.map(\.name) == ["clever_jackson", "shop-postgres-db-1", "shop-staging-postgres-db-1"])
        #expect(containers.map(\.isAlive) == [false, true, true])
        #expect(containers.map(\.state) == ["exited", "running", "running"])
        #expect(containers[1].image == "postgres:15.3")
        #expect(containers[1].id == "8740606cfa4e")
        // «>» en el JSON es «>»
        #expect(containers[1].ports == "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp")
        // Con `com.docker.compose.project.config_files` y `…working_dir` entre las etiquetas, el proyecto es el justo
        #expect(containers.map(\.project) == [nil, "shop", "shop-staging"])
    }

    @Test func readsTheHandWrittenComposeOutput() throws {
        let containers = DockerParser.parse(try Fixture.text("docker-ps-compose", extension: "jsonl"))
        #expect(containers.count == 7)
        #expect(containers.filter(\.isAlive).map(\.name) == ["shop-db-1", "shop-redis-1", "shop-web-1", "pg-dev", "blog-web-1"])
        #expect(containers.first { $0.name == "pg-dev" }?.project == nil)
        #expect(containers.first { $0.name == "old-test" }?.state == "created")
    }

    // Etiquetas con comas dentro de un valor no esconden la del proyecto
    @Test func theProjectComesFromItsLabel() {
        let labels = "a=1,org.opencontainers.image.keywords=PDF, manipulation, API,com.docker.compose.project=shop,b=2"
        #expect(DockerParser.project(in: labels) == "shop")
        #expect(DockerParser.project(in: "com.docker.compose.project.working_dir=/x") == nil)
        #expect(DockerParser.project(in: "com.docker.compose.project=") == nil)
        #expect(DockerParser.project(in: "") == nil)
    }

    @Test func badLinesAreSkippedAndAnEmptyOutputGivesNothing() {
        #expect(DockerParser.parse("").isEmpty)
        #expect(DockerParser.parse("no es json\n{\"ID\":\"x\"}\n\n").isEmpty)
    }

    @Test func aNameWithSeveralNamesKeepsTheFirstOne() {
        let line = #"{"ID":"abc","Names":"/web,/web-alias","Image":"i","State":"running","Status":"Up 1 second","Ports":"","Labels":""}"#
        #expect(DockerParser.parse(line).map(\.name) == ["web"])
    }
}

struct DockerStatusTests {
    @Test func publishedHostPortsWithoutRepeats() {
        #expect(DockerStatus.hostPorts("0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp") == [5432])
        #expect(DockerStatus.hostPorts("0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp") == [8080, 8443])
        // Un puerto solo expuesto no es accesible desde fuera
        #expect(DockerStatus.hostPorts("5432/tcp").isEmpty)
        #expect(DockerStatus.hostPorts("").isEmpty)
    }

    @Test(arguments: [
        ("Up 2 hours", "2 h"), ("Up About an hour", "1 h"), ("Up About an hour (healthy)", "1 h"),
        ("Up Less than a second", "<1 s"), ("Up 45 seconds", "45 s"), ("Up About a minute", "1 min"),
        ("Up 12 minutes", "12 min"), ("Up 3 days", "3 d"), ("Up 2 weeks (Paused)", "2 sem"), ("Up 1 hour", "1 h"),
    ])
    func uptimeIsShortened(status: String, expected: String) {
        #expect(DockerStatus.uptime(status) == expected)
    }

    @Test func aStoppedContainerHasNoUptime() {
        #expect(DockerStatus.uptime("Exited (0) 3 hours ago") == nil)
        #expect(DockerStatus.uptime("Created") == nil)
        #expect(DockerStatus.uptime("Up unknown thing") == nil)
    }
}

struct DockerRowsTests {
    private func containers(_ name: String) throws -> [DockerContainer] {
        DockerParser.parse(try Fixture.text(name, extension: "jsonl"))
    }

    private func rows(_ containers: [DockerContainer], showStopped: Bool = false) -> ModuleRowsContent {
        DockerRows.content(of: .containers(containers), showStopped: showStopped)
    }

    // Con la salida real: dos contenedores de proyectos distintos (uno solo en cada uno, así que no se agrupan) y uno parado
    @Test func aliveFirstWithTheStoppedOnesCollapsedIntoOneRow() throws {
        let content = rows(try containers("docker-ps"))
        #expect(content.summary == "2 en marcha")
        #expect(content.rows.map(\.title) == ["shop-postgres-db-1", "shop-staging-postgres-db-1", "+1 parados"])
        let first = content.rows[0]
        #expect(first.id == "container:8740606cfa4e")
        #expect(first.leading == .status(isOn: true))
        // El puerto y cuánto lleva en marcha («Up 4 minutes»)
        #expect(first.detail.hasPrefix(":5432 · ") && first.detail.hasSuffix(" min"))
        #expect(first.actions == [.restart, .stop])
        let footer = content.rows[2]
        #expect(footer.id == DockerRows.stoppedToggleID)
        #expect(footer.actions == [.showStopped] && footer.showsActionsAlways)
    }

    // Los proyectos de Compose con dos o más contenedores en marcha son una sola fila, con los botones del proyecto
    @Test func composeProjectsWithSeveralContainersAreGrouped() throws {
        let alive = try containers("docker-ps-compose").filter(\.isAlive)
        let content = rows(alive)
        #expect(content.summary == "5 en marcha")
        #expect(content.rows.map(\.title) == ["blog-web-1", "pg-dev", "shop"])
        let project = content.rows[2]
        #expect(project.id == "project:shop")
        #expect(project.detail == "3 contenedores")
        #expect(project.actions == [.restart, .stop])
        // Uno solo de un proyecto sigue siendo su contenedor; con puerto y desde cuándo
        #expect(content.rows[0].detail == ":8080 · 12 min")
        #expect(content.rows[1].detail == ":5433 · 3 d")
    }

    // Si hay parados, la última fila es «+n parados»: caben dos filas de contenedores y esa
    @Test func theStoppedToggleTakesTheThirdSlot() throws {
        let content = rows(try containers("docker-ps-compose"))
        #expect(content.rows.map(\.title) == ["blog-web-1", "pg-dev", "+2 parados"])
    }

    @Test func showingTheStoppedOnesOffersStartAndWayBack() throws {
        let content = rows(try containers("docker-ps-compose"), showStopped: true)
        #expect(content.summary == "2 parados")
        #expect(content.rows.map(\.title) == ["blog-db-1", "old-test", "Volver a los que corren"])
        #expect(content.rows[0].actions == [.start] && content.rows[0].leading == .status(isOn: false))
        #expect(content.rows[0].detail == "mysql:8")
        #expect(content.rows[2].actions == [.hideStopped] && content.rows[2].id == DockerRows.backID)
        // Sin parados, esa vista no tiene nada que enseñar: salen los que corren
        let alive = try containers("docker-ps-compose").filter(\.isAlive)
        #expect(rows(alive, showStopped: true).summary == "5 en marcha")
    }

    @Test func noneRunningSaysSoAndStillOffersTheStoppedOnes() throws {
        let stopped = try containers("docker-ps-compose").filter { !$0.isAlive }
        let content = rows(stopped)
        #expect(content.summary == "0 en marcha")
        #expect(content.rows.map(\.title) == ["Ninguno en marcha", "+2 parados"])
    }

    @Test func daemonAndInstallStatesAreNotices() {
        let stopped = DockerRows.content(of: .notRunning, showStopped: false)
        #expect(stopped.rows.isEmpty)
        #expect(stopped.notice?.title == "Docker no está en marcha")
        #expect(stopped.notice?.subtitle == "Abre Docker Desktop para ver los contenedores.")
        #expect(DockerRows.content(of: .notInstalled, showStopped: false).notice?.title == "Docker no está instalado")
        #expect(DockerRows.content(of: .containers([]), showStopped: false).notice?.title == "Sin contenedores")
        let waiting = DockerRows.content(of: nil, showStopped: false)
        #expect(waiting.rows.isEmpty && waiting.notice == nil)
    }

    @Test func aRowPointsAtItsContainerOrProject() {
        #expect(DockerRows.target(ofRow: "container:abc123") == ("abc123", nil))
        #expect(DockerRows.target(ofRow: "project:shop") == (nil, "shop"))
        #expect(DockerRows.target(ofRow: "docker:stopped") == (nil, nil))
    }
}

// El monitor con un `docker` falso: un script que escribe lo que se le pide
@MainActor
struct DockerMonitorTests {
    private func script(_ body: String) throws -> String { try FakeYabai.make(body) }

    @Test func readsTheContainersThatDockerPrints() async throws {
        let fixture = Fixture.directory.appending(path: "docker-ps.jsonl").path(percentEncoded: false)
        let monitor = DockerMonitor(executable: try script("cat '\(fixture)'"))
        await monitor.sampleOnce()
        guard case .containers(let containers) = monitor.state else {
            Issue.record("debería haber contenedores: \(String(describing: monitor.state))")
            return
        }
        #expect(containers.count == 3)
    }

    // Docker Desktop cerrado: `docker` sale con error y dice que no llega al demonio
    @Test func aFailingDockerMeansItIsNotRunning() async throws {
        let monitor = DockerMonitor(executable: try script("echo 'Cannot connect to the Docker daemon' >&2; exit 1"))
        await monitor.sampleOnce()
        #expect(monitor.state == .notRunning)
    }

    @Test func noDockerProgramMeansNotInstalled() async {
        let monitor = DockerMonitor(executable: nil)
        await monitor.sampleOnce()
        #expect(monitor.state == .notInstalled)
    }

    // Parar, reiniciar e iniciar ejecutan `docker <acción> <id>` o `docker compose -p <proyecto> <acción>`
    @Test func actionsRunTheRightCommands() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "docker-args-\(UUID().uuidString)").path(percentEncoded: false)
        let monitor = DockerMonitor(executable: try script("echo \"$@\" >> '\(log)'"))
        #expect(await monitor.run(.stop, container: "abc123"))
        #expect(await monitor.run(.restart, project: "shop"))
        #expect(await monitor.run(.start, container: "def456"))
        // Lo que no es una acción de Docker no ejecuta nada
        #expect(await !monitor.run(.open, container: "abc123"))
        #expect(await !monitor.run(.stop))
        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["stop abc123", "compose -p shop restart", "start def456"])
    }

    @Test func aFailingActionIsReported() async throws {
        let monitor = DockerMonitor(executable: try script("exit 1"))
        #expect(await !monitor.run(.stop, container: "abc"))
    }
}
