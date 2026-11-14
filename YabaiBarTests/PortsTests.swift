import Foundation
import Testing
@testable import YabaiBar

// lsof-listen.txt es la salida real de `lsof +c 0 -nP -iTCP -sTCP:LISTEN -F pcnuL` de esta máquina (con el nombre de
// usuario cambiado): ControlCenter y rapportd, que son de macOS, un servidor `node`, Claude Code y el servidor de
// Docker Desktop, con algún puerto escuchando en IPv4 e IPv6 a la vez
struct LsofParserTests {
    @Test func readsEveryListenerWithoutRepeatingTheSamePort() throws {
        let listeners = LsofParser.parse(try Fixture.text("lsof-listen"))
        // ControlCenter escucha dos veces en el 7000 y en el 5000 (dos descriptores cada uno), y rapportd en el 51809
        #expect(listeners.map(\.port) == [5000, 5432, 5433, 7000, 7265, 51809, 51967, 54122, 54123])
        #expect(listeners.filter { $0.command == "ControlCenter" }.map(\.port) == [5000, 7000])
        #expect(listeners.filter { $0.command == "rapportd" }.map(\.port) == [51809, 54122, 54123])
    }

    @Test func eachListenerKeepsItsProcess() throws {
        let node = try #require(LsofParser.parse(try Fixture.text("lsof-listen")).first { $0.port == 7265 })
        #expect(node.pid == 20003)
        #expect(node.command == "node")
        #expect(node.uid == 501)
        #expect(node.id == "20003:7265")
        #expect(node.url == URL(string: "http://localhost:7265"))
    }

    // Con `+c 0` el nombre sale entero: «com.docker.backend» tiene 18 letras
    @Test func fullCommandNamesAreKept() throws {
        let docker = LsofParser.parse(try Fixture.text("lsof-listen")).filter { $0.command == "com.docker.backend" }
        #expect(docker.map(\.port) == [5432, 5433])
    }

    @Test(arguments: [("*:7000", 7000), ("127.0.0.1:7265", 7265), ("[::1]:8080", 8080), ("[::]:80", 80)])
    func readsThePortOfAnyAddress(name: String, port: Int) {
        #expect(LsofParser.port(in: name) == port)
    }

    @Test func badNamesAndEmptyOutputGiveNothing() {
        #expect(LsofParser.port(in: "sin-puerto") == nil)
        #expect(LsofParser.port(in: "*:abc") == nil)
        #expect(LsofParser.parse("").isEmpty)
        // Un puerto sin proceso delante no se puede atribuir a nadie
        #expect(LsofParser.parse("f9\nn*:7000\n").isEmpty)
    }

    // El mismo proceso en dos puertos son dos filas; el mismo puerto en IPv4 e IPv6, una
    @Test func aProcessCanListenOnSeveralPorts() {
        let output = "p10\ncpython\nu501\nf3\nn127.0.0.1:8000\nf4\nn[::1]:8000\nf5\nn*:9000\n"
        #expect(LsofParser.parse(output).map(\.port) == [8000, 9000])
    }
}

struct PortRowsTests {
    private let me: UInt32 = 501
    private let myPID: Int32 = 4000

    private func listener(_ port: Int, _ command: String = "node", pid: Int32 = 100, uid: UInt32 = 501) -> PortListener {
        PortListener(pid: pid, command: command, uid: uid, port: port)
    }

    private func content(_ listeners: [PortListener]?) -> ModuleRowsContent {
        PortRows.content(of: listeners, ownUID: me, ownPID: myPID)
    }

    // Los servicios de macOS no son lo que se busca: salen del módulo
    @Test func macOSServicesAreLeftOut() throws {
        let real = try LsofParser.parse(Fixture.text("lsof-listen"))
        let shown = content(real)
        // Quedan 4 (los dos puertos de Docker, node y Claude Code); caben 3
        #expect(shown.rows.map(\.title) == ["com.docker.backend", "com.docker.backend", "node"])
        #expect(shown.summary == "3 de 4")
        #expect(!shown.rows.contains { ["ControlCenter", "rapportd"].contains($0.title) })
    }

    // Con el módulo Docker a la vista, los puertos de su servidor son los de los contenedores y salen allí
    @Test func dockerBackendPortsAreHiddenWhenTheDockerModuleShows() throws {
        let real = try LsofParser.parse(Fixture.text("lsof-listen"))
        let withDocker = PortRows.content(of: real, ownUID: me, ownPID: myPID, hidingDockerBackend: true)
        #expect(withDocker.rows.map(\.title) == ["node", "claude"])
        #expect(withDocker.summary == "2 abiertos")
        let withoutDocker = PortRows.content(of: real, ownUID: me, ownPID: myPID, hidingDockerBackend: false)
        #expect(withoutDocker.rows.first?.title == "com.docker.backend")
    }

    @Test(arguments: ["controlcenter", "ControlCenter", "RAPPORTD", "sharingd"])
    func hiddenNamesIgnoreCase(command: String) {
        #expect(SystemServices.isHidden(command))
    }

    @Test func aServerRowOffersOpenCopyAndClose() throws {
        let row = try #require(content([listener(3000)]).rows.first)
        #expect(row.id == "100:3000")
        #expect(row.leading == .code(":3000"))
        #expect(row.title == "node")
        #expect(row.actions == [.open, .copy, .close])
        #expect(!row.isDimmed)
    }

    // Solo se cierran los procesos del mismo usuario, nunca uno mismo, el pid 1 ni los protegidos
    @Test func onlyYourOwnProcessesCanBeClosed() {
        let rows = content([
            listener(3000, "node", pid: 100),
            listener(3001, "node", pid: 101, uid: 0),
            listener(3002, "YabaiBar", pid: myPID),
        ]).rows
        #expect(rows[0].actions.contains(.close))
        #expect(rows[1].actions == [.open, .copy])
        #expect(rows[1].detail == "de otro usuario" && rows[1].isDimmed)
        // La propia isla no se cierra a sí misma
        #expect(rows[2].actions == [.open, .copy])
    }

    // Ni el pid 1, ni el servidor de Docker Desktop: pararlo se llevaría los contenedores por delante
    @Test func protectedProcessesCannotBeClosed() {
        let rows = content([
            listener(3003, "otro", pid: 1),
            listener(5432, "com.docker.backend", pid: 102),
            listener(5433, "Com.Docker.Backend", pid: 103),
        ]).rows
        #expect(rows.map(\.actions) == [[.open, .copy], [.open, .copy], [.open, .copy]])
    }

    // Caben 3 filas: con más, la cabecera dice cuántas son
    @Test func moreThanThreeShowTheFirstThreeAndTheTotal() {
        let shown = content((1...5).map { listener(3000 + $0, pid: Int32(100 + $0)) })
        #expect(shown.rows.count == 3)
        #expect(shown.rows.map(\.leading) == [.code(":3001"), .code(":3002"), .code(":3003")])
        #expect(shown.summary == "3 de 5")
    }

    @Test func noListenersShowANoticeAndNoMeasureYetShowsNothing() {
        let empty = content([])
        #expect(empty.rows.isEmpty)
        #expect(empty.notice?.title == "Ningún puerto abierto")
        let beforeTheFirstMeasure = content(nil)
        #expect(beforeTheFirstMeasure.rows.isEmpty && beforeTheFirstMeasure.notice == nil)
    }
}

// Un servidor de verdad en un puerto, para comprobar `lsof` y el monitor sin imitarlos
private final class LocalListener {
    let descriptor: Int32
    let port: Int

    init?() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard bound == 0, named == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func stop() { close(descriptor) }
}

@MainActor
struct PortsMonitorTests {
    // El monitor ve un servidor que acaba de abrirse, y deja de verlo cuando se cierra
    @Test func seesARealListenerAndWhenItCloses() async throws {
        let listener = try #require(LocalListener())
        let monitor = PortsMonitor()
        let mine = PortListener(pid: getpid(), command: "", uid: getuid(), port: listener.port)
        let found = try #require(await PortsMonitor.listening(runner: CommandRunner(timeout: 5)))
        let ours = try #require(found.first { $0.port == listener.port })
        #expect(ours.pid == getpid() && ours.uid == getuid())
        // Con el nombre que da lsof, sigue escuchando
        #expect(await monitor.isStillListening(ours))
        listener.stop()
        #expect(await !monitor.isStillListening(ours))
        #expect(!mine.id.isEmpty)
    }

    // Un pid que ya es de otro proceso (mismo puerto, otro nombre) no cuenta: no se le manda la señal
    @Test func anotherProcessOnTheSamePortIsNotTheSameListener() async throws {
        let listener = try #require(LocalListener())
        defer { listener.stop() }
        let monitor = PortsMonitor()
        let stranger = PortListener(pid: getpid(), command: "otro", uid: getuid(), port: listener.port)
        #expect(await !monitor.isStillListening(stranger))
    }

    @Test func startAndStopTrackTheMonitorAndClearItsData() async throws {
        let monitor = PortsMonitor()
        monitor.start()
        #expect(monitor.isRunning)
        var waited = 0
        while monitor.listeners == nil && waited < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        #expect(monitor.listeners != nil)
        monitor.stop()
        #expect(!monitor.isRunning && monitor.listeners == nil)
    }
}
