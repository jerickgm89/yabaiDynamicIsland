import Foundation
import Testing
@testable import YabaiBar

// El almacén de sesiones de Claude Code con una carpeta temporal en vez de ~/.claude/sessions: lectura de archivos, hooks y
// avisos. Nada toca la carpeta real.
@MainActor
struct ClaudeSessionsTests {
    private func writeSession(
        _ directory: URL, pid: Int32, session: String, status: String = "busy", cwd: String = "/Users/user/web", procStart: String? = nil
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fields: [String: Any] = ["pid": pid, "sessionId": session, "cwd": cwd, "status": status, "entrypoint": "cli", "name": "t"]
        if let procStart { fields["procStart"] = procStart }
        try JSONSerialization.data(withJSONObject: fields).write(to: directory.appending(path: "\(pid).json"))
    }

    // MARK: Leer la carpeta

    @Test func aMissingFolderMeansNoSessionsAndAnUnreadableOneMeansUnknown() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        #expect(ClaudeSessionReader.read(in: root.appending(path: "no-existe")) == [])
        // Un archivo donde se esperaba la carpeta: existe, pero no se puede listar
        let file = root.appending(path: "archivo")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeSessionReader.read(in: file) == nil)
    }

    @Test func onlyLiveProcessesAreSessions() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let directory = root.appending(path: "sessions")
        try writeSession(directory, pid: 1001, session: "viva")
        try writeSession(directory, pid: 1002, session: "muerta")
        // Un archivo roto, uno que no es una sesión y un .key: se saltan
        try Data("roto".utf8).write(to: directory.appending(path: "1003.json"))
        try Data(#"{"otra":"cosa"}"#.utf8).write(to: directory.appending(path: "1004.json"))
        try Data("token-secreto".utf8).write(to: directory.appending(path: "1001.0000.key"))
        let records = try #require(ClaudeSessionReader.read(in: directory, isAlive: { $0 == 1001 }, startDate: { _ in nil }))
        #expect(records.map(\.sessionID) == ["viva"])
    }

    // Nunca se abre un .key
    @Test func keyFilesAreNeverRead() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let directory = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Un .key con la forma de una sesión: si se leyera, saldría
        let fake = #"{"pid":1001,"sessionId":"del-key"}"#
        try Data(fake.utf8).write(to: directory.appending(path: "1001.key"))
        try Data(fake.utf8).write(to: directory.appending(path: "1001.json.key"))
        let records = ClaudeSessionReader.read(in: directory, isAlive: { _ in true }, startDate: { _ in nil })
        #expect(records == [])
    }

    @Test func aReusedPidIsNotASession() throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let directory = root.appending(path: "sessions")
        try writeSession(directory, pid: 1001, session: "a", procStart: "Thu Nov 12 23:06:09 2026")
        let start = Date(timeIntervalSince1970: 1_794_524_769)
        let same = ClaudeSessionReader.read(in: directory, isAlive: { _ in true }, startDate: { _ in start })
        #expect(same?.count == 1)
        let reused = ClaudeSessionReader.read(in: directory, isAlive: { _ in true }, startDate: { _ in start.addingTimeInterval(3600) })
        #expect(reused == [])
    }

    // El proceso de los tests es de verdad un proceso vivo
    @Test func theProbeKnowsOurOwnProcess() {
        let pid = getpid()
        #expect(ProcessProbe.isAlive(pid))
        #expect(!ProcessProbe.isAlive(Int32.max - 1))
        let start = ProcessProbe.startDate(of: pid)
        #expect(start != nil && start! < Date())
        #expect(ProcessProbe.parentPID(of: pid) != nil)
        #expect(ProcessProbe.startDate(of: Int32.max - 1) == nil)
    }

    // MARK: El almacén

    @Test func readsSessionsOnlyWhileVisible() async throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let directory = root.appending(path: "sessions")
        // Esta sesión es de verdad un proceso vivo: el de los tests
        try writeSession(directory, pid: getpid(), session: "a", status: "busy")
        let claude = try ClaudeTestSupport.sessions(directory: directory)
        #expect(claude.sessions == nil && !claude.isRunning)
        claude.setVisible(true)
        #expect(claude.isRunning)
        try await waitUntil { claude.sessions != nil }
        #expect(claude.sessions?.map(\.id) == ["a"] && claude.sessions?.first?.state == .working)
        claude.setVisible(false)
        #expect(claude.sessions == nil && !claude.isRunning)
    }

    @Test func aHookEventMakesAnOutcomeAndTheWaitingCount() throws {
        let claude = try ClaudeTestSupport.sessions()
        final class Seen { var outcomes: [ClaudeOutcome] = [] }
        let seen = Seen()
        claude.onOutcome = { seen.outcomes.append($0) }
        let event = ClaudeHookEvent(name: .notification, sessionID: "a", cwd: "/x/web", kind: "permission_prompt", message: "hola")
        claude.handle(AvisoMessage(event))
        #expect(seen.outcomes == [.asks(sessionID: "a", cwd: "/x/web", message: "hola")])
        #expect(claude.waitingCount == 1)
        // Mientras alguna espera se sigue leyendo la carpeta, aunque la pestaña no se vea
        #expect(claude.isRunning)
        claude.handle(AvisoMessage(ClaudeHookEvent(name: .postToolUse, sessionID: "a", cwd: "/x/web", kind: "Bash")))
        #expect(claude.waitingCount == 0)
        #expect(!claude.isRunning)
    }

    @Test func noticesThatAreNotClaudeEventsAreIgnored() throws {
        let claude = try ClaudeTestSupport.sessions()
        claude.handle(AvisoMessage(kind: .claudeHook, fields: ["event": "Otro", "session": "a"]))
        claude.handle(AvisoMessage(kind: .claudeHook, fields: [:]))
        #expect(claude.waitingCount == 0 && !claude.isRunning)
    }

    // Una sesión que espera y cuyo proceso se cierra deja de esperar en la siguiente lectura
    @Test func aWaitingSessionThatClosesStopsWaiting() async throws {
        let root = try ClaudeTestSupport.temporaryDirectory()
        let directory = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claude = try ClaudeTestSupport.sessions(directory: directory)
        claude.handle(AvisoMessage(ClaudeHookEvent(name: .notification, sessionID: "a", cwd: "/x/web", kind: "permission_prompt")))
        #expect(claude.waitingCount == 1)
        // La carpeta está vacía: no hay ninguna sesión abierta, así que «a» ya no existe
        try await waitUntil { claude.waitingCount == 0 }
        #expect(!claude.isRunning)
    }

    @Test func rowsFollowTheSessionsAndTheConnection() throws {
        let claude = try ClaudeTestSupport.sessions()
        let record = ClaudeSessionRecord(
            pid: 5, sessionID: "a", cwd: "/x/web", name: "Arreglar", status: "busy", entrypoint: "cli", procStart: "", statusUpdatedAt: nil
        )
        claude.inject(records: [record])
        let content = ClaudeRows.content(of: claude.sessions, connected: claude.connection.status.map { $0 == .connected })
        #expect(content.rows.first?.title == "web" && content.rows.first?.trailing == "Trabajando")
    }

    // Esperar a que algo pase sin dormir de más
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "no ocurrió a tiempo")
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

// Los avisos de verdad, por DistributedNotificationCenter
@MainActor
struct NoticeCenterTests {
    // Un nombre propio de cada prueba: con el real, escucharían los avisos de las sesiones de verdad (y las inundaciones de
    // estos tests llegarían a la app que corre)
    private let name = Notification.Name("com.jerickdev.yabaibar.aviso.test.\(UUID().uuidString)")

    private func post(_ userInfo: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: userInfo, deliverImmediately: true
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "el aviso no llegó")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    final class Received { var messages: [AvisoMessage] = [] }

    @Test func aWellFormedNoticeArrivesAndABadOneDoesNot() async throws {
        let center = NoticeCenter(name: name)
        let received = Received()
        center.start { received.messages.append($0) }
        defer { center.stop() }
        // Un aviso mal formado, y después uno bueno: llega solo el bueno
        post(["kind": "otra-cosa"])
        post(["kind": "claude-hook", "event": "Stop", "session": "prueba-noticecenter", "cwd": "/x/web"])
        try await waitUntil { !received.messages.isEmpty }
        // Da tiempo a que llegue, si fuera a hacerlo, el malo
        try await Task.sleep(for: .milliseconds(200))
        #expect(received.messages.count == 1)
        #expect(received.messages.first?.claudeEvent?.sessionID == "prueba-noticecenter")
    }

    @Test func noticesStopArrivingAfterStop() async throws {
        let center = NoticeCenter(name: name)
        let received = Received()
        center.start { received.messages.append($0) }
        center.stop()
        post(["kind": "claude-hook", "event": "Stop", "session": "x"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.messages.isEmpty)
    }

    // Más avisos de los que se permiten por ventana se descartan
    @Test func aFloodIsLimited() async throws {
        let center = NoticeCenter(name: name, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let received = Received()
        center.start { received.messages.append($0) }
        defer { center.stop() }
        for index in 0..<(NoticeCenter.limit + 30) {
            post(["kind": "claude-hook", "event": "Stop", "session": "inundacion-\(index)"])
        }
        try await waitUntil { received.messages.count >= NoticeCenter.limit }
        try await Task.sleep(for: .milliseconds(500))
        #expect(received.messages.count == NoticeCenter.limit)
    }

    // Un bucle de avisos de la terminal no gasta el cupo de los hooks de Claude (ni deja una pregunta colgada)
    @Test func eachKindHasItsOwnQuota() async throws {
        let center = NoticeCenter(name: name, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let received = Received()
        center.start { received.messages.append($0) }
        defer { center.stop() }
        for index in 0..<(NoticeCenter.terminalLimit + 40) {
            post(["kind": "terminal", "event": "custom", "title": "bucle \(index)"])
        }
        for index in 0..<5 {
            post(["kind": "claude-hook", "event": "Stop", "session": "claude-\(index)"])
        }
        try await waitUntil { received.messages.filter { $0.kind == .claudeHook }.count >= 5 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(received.messages.filter { $0.kind == .terminal }.count == NoticeCenter.terminalLimit)
        #expect(received.messages.filter { $0.kind == .claudeHook }.count == 5)
    }
}

// El ayudante de verdad, el que va dentro de la app (Contents/Helpers/yb): un hook nunca tiene que dar error ni escribir nada
struct ClaudeHelperTests {
    private var helper: String { Bundle.main.bundleURL.appending(path: "Contents/Helpers/yb").path }

    // Ejecuta `yb claude-hook` con la entrada que se diga (`<&-` es stdin cerrado)
    private func run(_ redirect: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "'\(helper)' claude-hook \(redirect)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func theHelperIsInsideTheApp() {
        #expect(FileManager.default.isExecutableFile(atPath: helper))
    }

    @Test func itAlwaysExitsWithZeroAndWritesNothing() throws {
        // Stdin cerrado (lanzaba una excepción de Objective-C y salía con 134), vacío y basura
        for redirect in ["<&-", "</dev/null", "<<< 'no es json'", "<<< '{\"hook_event_name\":\"Stop\"}'"] {
            let result = try run(redirect)
            #expect(result.status == 0 && result.output.isEmpty, "\(redirect): \(result.status) \(result.output)")
        }
    }
}
