import Foundation
import Testing
@testable import YabaiBar

// Lógica pura del módulo Claude Code: el archivo de sesión, el estado a partir de los hooks, las filas y el aviso.
struct ClaudeSessionRecordTests {
    @Test func parsesADesktopSession() throws {
        let record = try #require(ClaudeSessionRecord.parse(Fixture.data("claude-session-desktop")))
        #expect(record.pid == 41001)
        #expect(record.sessionID == "0b6d1a52-7f3c-4c1e-9a55-2f0f6a1d0c01")
        #expect(record.folder == "tienda")
        #expect(record.name == "Arreglar el carrito")
        #expect(record.status == "busy")
        #expect(record.origin == .desktopApp)
        #expect(record.statusUpdatedAt == Date(timeIntervalSince1970: 1_794_524_867.716))
    }

    // Una sesión de terminal, sin título
    @Test func parsesATerminalSession() throws {
        let record = try #require(ClaudeSessionRecord.parse(Fixture.data("claude-session-terminal")))
        #expect(record.pid == 41002 && record.origin == .terminal && record.status == "idle")
        #expect(record.name.isEmpty && record.folder == "api")
    }

    @Test func aFileWithoutPidOrSessionIsNotASession() {
        for text in ["", "no es json", "[]", #"{"pid":0,"sessionId":"x"}"#, #"{"pid":5}"#, #"{"sessionId":"x"}"#, #"{"pid":5,"sessionId":""}"#] {
            #expect(ClaudeSessionRecord.parse(Data(text.utf8)) == nil, "\(text)")
        }
        // Lo único que hace falta es el pid y el id: un campo que falte no la rompe
        let minimal = ClaudeSessionRecord.parse(Data(#"{"pid":5,"sessionId":"x"}"#.utf8))
        #expect(minimal?.status == "" && minimal?.cwd == "")
    }

    // `procStart` es la hora de arranque del proceso en UTC, tal como la escribe ps
    @Test func readsTheProcessStartTime() throws {
        let record = try #require(ClaudeSessionRecord.parse(Fixture.data("claude-session-desktop")))
        #expect(record.startDate == Date(timeIntervalSince1970: 1_794_524_769))
        #expect(ClaudeSessionRecord.parse(Data(#"{"pid":5,"sessionId":"x","procStart":"ayer"}"#.utf8))?.startDate == nil)
    }

    // Un pid que se heredó: otro proceso con el mismo número no es la sesión
    @Test func aReusedPidIsNotTheSameProcess() throws {
        let record = try #require(ClaudeSessionRecord.parse(Fixture.data("claude-session-desktop")))
        let start = Date(timeIntervalSince1970: 1_794_524_769)
        #expect(record.isSameProcess(startedAt: start))
        #expect(record.isSameProcess(startedAt: start.addingTimeInterval(2)))
        #expect(!record.isSameProcess(startedAt: start.addingTimeInterval(30)))
        #expect(!record.isSameProcess(startedAt: nil))
        // Sin hora en el archivo solo cuenta que viva
        let noStart = try #require(ClaudeSessionRecord.parse(Data(#"{"pid":5,"sessionId":"x"}"#.utf8)))
        #expect(noStart.isSameProcess(startedAt: nil))
    }
}

struct ClaudeSessionStatesTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func event(
        _ name: ClaudeHookEvent.Name, kind: String = "", message: String = "", session: String = "a", cwd: String = "/Users/user/web"
    ) -> ClaudeHookEvent {
        ClaudeHookEvent(name: name, sessionID: session, cwd: cwd, kind: kind, message: message)
    }

    private func record(_ session: String, status: String, folder: String = "web", pid: Int32 = 100) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            pid: pid, sessionID: session, cwd: "/Users/user/\(folder)", name: "", status: status, entrypoint: "cli", procStart: "",
            statusUpdatedAt: nil
        )
    }

    @Test func aPermissionPromptWaitsAndAnswersTheOutcome() {
        var states = ClaudeSessionStates()
        let outcome = states.apply(event(.notification, kind: "permission_prompt", message: "Claude needs your permission"), at: at(0))
        #expect(outcome == .asks(sessionID: "a", cwd: "/Users/user/web", message: "Claude needs your permission"))
        #expect(states.waitingCount == 1)
    }

    // Los Notification que no son una petición no cuentan: idle_prompt es «terminé hace un minuto»
    @Test func otherNotificationsDoNotWait() {
        var states = ClaudeSessionStates()
        for kind in ["idle_prompt", "auth_success", "", "algo_nuevo"] {
            let result1 = states.apply(event(.notification, kind: kind), at: at(0))
            #expect(result1 == nil, "\(kind)")
        }
        #expect(states.waitingCount == 0)
        for kind in ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "worker_permission_prompt"] {
            var other = ClaudeSessionStates()
            let result2 = other.apply(event(.notification, kind: kind), at: at(0))
            #expect(result2 != nil, "\(kind)")
        }
    }

    @Test func onlyTheAskingToolsWait() {
        var states = ClaudeSessionStates()
        let result3 = states.apply(event(.preToolUse, kind: "Bash"), at: at(0))
        #expect(result3 == nil)
        #expect(states.waitingCount == 0)
        let ask = states.apply(event(.preToolUse, kind: "AskUserQuestion"), at: at(1))
        #expect(ask == .asks(sessionID: "a", cwd: "/Users/user/web", message: "Te hace una pregunta"))
        var plan = ClaudeSessionStates()
        let outcome = plan.apply(event(.preToolUse, kind: "ExitPlanMode"), at: at(0))
        #expect(outcome == .asks(sessionID: "a", cwd: "/Users/user/web", message: "Tiene un plan por aprobar"))
    }

    // Un permiso suele llegar como PreToolUse y como Notification: avisa una sola vez
    @Test func askingTwiceNoticesOnce() {
        var states = ClaudeSessionStates()
        let result4 = states.apply(event(.preToolUse, kind: "AskUserQuestion"), at: at(0))
        #expect(result4 != nil)
        let result5 = states.apply(event(.notification, kind: "permission_prompt"), at: at(1))
        #expect(result5 == nil)
        #expect(states.waitingCount == 1)
        #expect(states.waiting["a"]?.since == at(0))
    }

    @Test func answeringStopsTheWait() {
        for answer in [ClaudeHookEvent.Name.postToolUse, .userPromptSubmit, .stop] {
            var states = ClaudeSessionStates()
            _ = states.apply(event(.notification, kind: "permission_prompt"), at: at(0))
            _ = states.apply(event(answer, kind: "Bash"), at: at(5))
            #expect(states.waitingCount == 0, "\(answer)")
        }
    }

    @Test func eachSessionWaitsOnItsOwn() {
        var states = ClaudeSessionStates()
        _ = states.apply(event(.notification, kind: "permission_prompt", session: "a"), at: at(0))
        _ = states.apply(event(.notification, kind: "permission_prompt", session: "b"), at: at(1))
        #expect(states.waitingCount == 2)
        _ = states.apply(event(.postToolUse, kind: "Bash", session: "a"), at: at(2))
        #expect(states.waitingCount == 1 && states.waiting["b"] != nil)
    }

    @Test func stopReportsHowLongItWorked() {
        var states = ClaudeSessionStates()
        _ = states.apply(event(.userPromptSubmit), at: at(0))
        let outcome = states.apply(event(.stop), at: at(95))
        #expect(outcome == .finished(sessionID: "a", cwd: "/Users/user/web", duration: 95))
        // Sin haber visto el mensaje que lo empezó, no se sabe cuánto trabajó
        var unknown = ClaudeSessionStates()
        let result6 = unknown.apply(event(.stop), at: at(10))
        #expect(result6 == .finished(sessionID: "a", cwd: "/Users/user/web", duration: nil))
    }

    // Si la app se abre con Claude trabajando, el primer PostToolUse empieza la cuenta
    @Test func aToolEventStartsTheCountWhenThePromptWasMissed() {
        var states = ClaudeSessionStates()
        _ = states.apply(event(.postToolUse, kind: "Read"), at: at(0))
        _ = states.apply(event(.postToolUse, kind: "Read"), at: at(40))
        let result7 = states.apply(event(.stop), at: at(60))
        #expect(result7 == .finished(sessionID: "a", cwd: "/Users/user/web", duration: 60))
    }

    @Test func theFileStatusDoesNotUndoAQuestion() {
        var states = ClaudeSessionStates()
        _ = states.apply(event(.notification, kind: "permission_prompt"), at: at(0))
        // Aunque el archivo diga reposo, la pregunta sigue en pie hasta que se responda
        #expect(states.state(of: record("a", status: "idle")) == .waiting)
        #expect(states.state(of: record("a", status: "busy")) == .waiting)
        #expect(states.state(of: record("b", status: "busy")) == .working)
        #expect(states.state(of: record("b", status: "idle")) == .idle)
        #expect(states.state(of: record("b", status: "otra-cosa")) == .idle)
        // Un comando en marcha es trabajo
        #expect(states.state(of: record("b", status: "shell")) == .working)
    }

    // Cualquier proceso puede mandar avisos con ids inventados: lo recordado tiene tope
    @Test func whatIsRememberedHasALimit() {
        var states = ClaudeSessionStates()
        for index in 0..<(ClaudeSessionStates.maxTracked * 3) {
            _ = states.apply(event(.notification, kind: "permission_prompt", session: "s\(index)"), at: at(Double(index)))
            _ = states.apply(event(.userPromptSubmit, session: "p\(index)"), at: at(Double(index)))
        }
        #expect(states.waitingCount <= ClaudeSessionStates.maxTracked)
        // Quedan las más recientes
        #expect(states.waiting["s\(ClaudeSessionStates.maxTracked * 3 - 1)"] != nil && states.waiting["s0"] == nil)
    }

    @Test func oldQuestionsExpireAndClosedSessionsAreForgotten() {
        var states = ClaudeSessionStates()
        _ = states.apply(event(.notification, kind: "permission_prompt", session: "a"), at: at(0))
        _ = states.apply(event(.notification, kind: "permission_prompt", session: "b"), at: at(10))
        // No se pudo leer la carpeta: solo cuenta el tiempo
        states.prune(records: nil, at: at(60))
        #expect(states.waitingCount == 2)
        // La sesión «a» ya no está abierta
        states.prune(records: [record("b", status: "busy")], at: at(60))
        #expect(states.waitingCount == 1 && states.waiting["b"] != nil)
        // Pasada media hora sin respuesta
        states.prune(records: [record("b", status: "busy")], at: at(10 + ClaudeSessionStates.expiry + 1))
        #expect(states.waitingCount == 0)
    }

    @Test func sessionsAreSortedWaitingFirstThenWorkingThenIdle() {
        var states = ClaudeSessionStates()
        _ = states.apply(event(.notification, kind: "permission_prompt", session: "w"), at: at(0))
        let sessions = states.sessions(from: [
            record("i", status: "idle", folder: "alfa", pid: 1),
            record("k", status: "busy", folder: "zeta", pid: 2),
            record("w", status: "busy", folder: "mu", pid: 3),
            record("j", status: "busy", folder: "beta", pid: 4),
        ])
        #expect(sessions.map(\.id) == ["w", "j", "k", "i"])
        let states4: [ClaudeSessionState] = sessions.map(\.state)
        #expect(states4 == [.waiting, .working, .working, .idle])
    }
}

struct ClaudeRowsTests {
    private func session(_ id: String, _ state: ClaudeSessionState, folder: String = "web", title: String = "") -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, folder: folder, title: title, origin: .terminal, state: state)
    }

    @Test func nothingIsShownBeforeTheFirstRead() {
        let content = ClaudeRows.content(of: nil, connected: nil)
        #expect(content.rows.isEmpty && content.notice == nil && content.summary.isEmpty)
    }

    @Test func noSessionsSaysSo() {
        let content = ClaudeRows.content(of: [], connected: true)
        #expect(content.rows.map(\.id) == [ClaudeRows.noneID])
        #expect(content.rows.first?.title == "Ninguna sesión abierta")
        #expect(content.summary.isEmpty)
    }

    @Test func aRowShowsFolderTitleAndState() {
        let content = ClaudeRows.content(of: [session("a", .waiting, folder: "tienda", title: "Arreglar el carrito")], connected: true)
        let row = content.rows[0]
        #expect(row.id == "session:a" && ClaudeRows.sessionID(ofRow: row.id) == "a")
        #expect(row.title == "tienda" && row.detail == "Arreglar el carrito" && row.trailing == "Pregunta")
        #expect(row.tone == .attention && row.leading == .dot(.attention))
        #expect(row.primaryAction == .activate && row.actions.isEmpty)
        #expect(content.summary == "1 sesión")
    }

    @Test func eachStateHasItsLabelAndTone() {
        let content = ClaudeRows.content(
            of: [session("a", .waiting), session("b", .working), session("c", .idle)], connected: true
        )
        let labels = content.rows.map(\.trailing)
        #expect(labels == ["Pregunta", "Trabajando", "En reposo"])
        let tones: [RowTone] = content.rows.map(\.tone)
        #expect(tones == [.attention, .active, .neutral])
        #expect(content.summary == "3 sesiones")
    }

    // Sin los hooks, la tercera fila es la invitación a conectarlos
    @Test func withoutHooksTheLastRowInvitesToConnect() {
        let content = ClaudeRows.content(of: [session("a", .working)], connected: false)
        #expect(content.rows.count == 2)
        let invitation = content.rows[1]
        #expect(invitation.id == ClaudeRows.connectID && invitation.actions == [.connect] && invitation.showsActionsAlways)
        #expect(invitation.title == "No avisa de las preguntas")
        // También sin ninguna sesión abierta
        let none = ClaudeRows.content(of: [], connected: false)
        #expect(none.rows.map(\.id) == [ClaudeRows.noneID, ClaudeRows.connectID])
        // Con los hooks (o sin saberlo todavía), no se invita
        #expect(!ClaudeRows.content(of: [session("a", .idle)], connected: true).rows.contains { $0.id == ClaudeRows.connectID })
        #expect(!ClaudeRows.content(of: [session("a", .idle)], connected: nil).rows.contains { $0.id == ClaudeRows.connectID })
    }

    @Test func neverMoreThanThreeRows() {
        let many = (1...6).map { session("s\($0)", .idle, folder: "p\($0)") }
        let connected = ClaudeRows.content(of: many, connected: true)
        #expect(connected.rows.count == ModuleRowLayout.maxRows)
        #expect(connected.summary == "3 de 6")
        // Con la invitación, caben dos sesiones y ella
        let invited = ClaudeRows.content(of: many, connected: false)
        #expect(invited.rows.count == ModuleRowLayout.maxRows && invited.rows.last?.id == ClaudeRows.connectID)
        #expect(invited.summary == "2 de 6")
    }
}

struct ClaudePeekTests {
    @Test func aQuestionTellsTheFolderAndWhatClaudeSays() {
        let peek = ClaudePeek.make(for: .asks(sessionID: "a", cwd: "/Users/user/proyectos/tienda", message: "Claude needs your permission"), notifyFinished: false)
        #expect(peek?.title == "Claude pregunta")
        #expect(peek?.subtitle == "tienda · Claude needs your permission")
        #expect(peek?.kind == .asks)
        let silent = ClaudePeek.make(for: .asks(sessionID: "a", cwd: "/x/web", message: ""), notifyFinished: false)
        #expect(silent?.subtitle == "web · Espera tu respuesta")
        let nowhere = ClaudePeek.make(for: .asks(sessionID: "a", cwd: "", message: ""), notifyFinished: false)
        #expect(nowhere?.subtitle == "Claude Code · Espera tu respuesta")
    }

    @Test func finishingOnlyNoticesWhenAskedAndAfterWorkingLongEnough() {
        let long = ClaudeOutcome.finished(sessionID: "a", cwd: "/x/web", duration: 95)
        #expect(ClaudePeek.make(for: long, notifyFinished: false) == nil)
        let peek = ClaudePeek.make(for: long, notifyFinished: true)
        #expect(peek?.title == "Claude terminó" && peek?.subtitle == "web · tras 2 min" && peek?.kind == .finished)
        let short = ClaudeOutcome.finished(sessionID: "a", cwd: "/x/web", duration: 29)
        #expect(ClaudePeek.make(for: short, notifyFinished: true) == nil)
        let unknown = ClaudeOutcome.finished(sessionID: "a", cwd: "/x/web", duration: nil)
        #expect(ClaudePeek.make(for: unknown, notifyFinished: true) == nil)
        let exact = ClaudeOutcome.finished(sessionID: "a", cwd: "/x/web", duration: 30)
        #expect(ClaudePeek.make(for: exact, notifyFinished: true) != nil)
    }

    @Test func durationsAreSpokenShort() {
        #expect(ClaudePeek.spoken(45) == "45 s")
        #expect(ClaudePeek.spoken(60) == "1 min")
        #expect(ClaudePeek.spoken(185) == "3 min")
        #expect(ClaudePeek.spoken(3600) == "1 h")
        #expect(ClaudePeek.spoken(3900) == "1 h 5 min")
    }

    // Una pregunta se ve más y manda sobre los demás avisos; terminar es menos importante que el Pomodoro
    @Test func theQuestionIsTheMostImportantPeek() {
        let ask = IslandPeek.claude(ClaudePeek(kind: .asks, folder: "web", detail: "x"))
        let finished = IslandPeek.claude(ClaudePeek(kind: .finished, folder: "web", detail: "x"))
        #expect(ask.duration == .seconds(8) && finished.duration == .seconds(5))
        #expect(ask.widensWings && finished.widensWings)
        let pomodoro = IslandPeek.shortcuts(title: "a", subtitle: "b")
        #expect(ask.priority > pomodoro.priority)
        #expect(finished.priority <= pomodoro.priority)
        // El log no lleva la carpeta ni el mensaje
        #expect(ask.summary == "Claude pregunta" && !ask.summary.contains("web"))
    }
}

struct ClaudeSupportTests {
    @Test func theRateLimiterDropsTheExcess() {
        var limiter = EventRateLimiter(limit: 3, window: 5)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = limiter.allow(at: t0)
        let second = limiter.allow(at: t0.addingTimeInterval(1))
        let third = limiter.allow(at: t0.addingTimeInterval(2))
        #expect(first && second && third)
        let excess = limiter.allow(at: t0.addingTimeInterval(3))
        #expect(!excess)
        // Pasada la ventana desde los primeros, vuelve a dejar pasar
        let later = limiter.allow(at: t0.addingTimeInterval(5.5))
        #expect(later)
    }

    // Procesos: 100 → 90 (shell) → 80 (terminal, una app) → 1
    @Test func theOriginIsTheFirstAppAmongTheParents() {
        let parents: [Int32: Int32] = [100: 90, 90: 80, 80: 1]
        let found = ProcessAncestry.firstApp(from: 100, parent: { parents[$0] }, isApp: { $0 == 80 })
        #expect(found == 80)
        // Ninguna de las que cuelgan es una app
        #expect(ProcessAncestry.firstApp(from: 100, parent: { parents[$0] }, isApp: { _ in false }) == nil)
        // Un pid sin padre
        #expect(ProcessAncestry.firstApp(from: 7, parent: { _ in nil }, isApp: { _ in true }) == nil)
        // Un ciclo no se queda dando vueltas
        let loop: [Int32: Int32] = [5: 6, 6: 5]
        #expect(ProcessAncestry.firstApp(from: 5, parent: { loop[$0] }, isApp: { _ in false }) == nil)
        // La propia sesión no cuenta, solo lo que la contiene
        #expect(ProcessAncestry.firstApp(from: 100, parent: { parents[$0] }, isApp: { $0 == 100 }) == nil)
    }

    @Test func folderNames() {
        #expect(ClaudeFolder.name(of: "/Users/user/proyectos/tienda") == "tienda")
        #expect(ClaudeFolder.name(of: "/Users/user/proyectos/tienda/") == "tienda")
        #expect(ClaudeFolder.name(of: "/") == "/")
        #expect(ClaudeFolder.name(of: "") == "Claude Code")
    }
}

// Un clic en una fila de Claude Code: en cualquier parte de la fila de una sesión, ir a ella; en la invitación, solo su botón
struct ClaudeRowHitTests {
    private let layout = IslandExpandedLayout(
        spaces: (1...4).map { SpaceSummary(index: $0, isFocused: $0 == 1, apps: []) }, minBodyWidth: 396, maxBodyWidth: 1958,
        topHeight: 38, tab: .developer, tabs: IslandTab.allCases, hasKeepAwake: true, hasSettingsButton: true
    )

    // El punto (en coordenadas de la isla) a `dx` del borde izquierdo de la fila `index` del módulo, a media altura
    private func point(row index: Int, dx: CGFloat) throws -> CGPoint {
        let origin = layout.activityOrigin(islandWidth: 808, topHeight: 38)
        let cell = try #require(layout.developerGrid.cells.first { $0.module == .claude })
        let frame = ModuleRowLayout.rowFrame(index, in: cell.frame.size)
        return CGPoint(x: origin.x + cell.frame.minX + frame.minX + dx, y: origin.y + cell.frame.minY + frame.midY)
    }

    private func rows(connected: Bool) -> [ModuleID: [ModuleRow]] {
        let session = ClaudeSession(id: "a", pid: 1, folder: "web", title: "t", origin: .terminal, state: .working)
        return [.claude: ClaudeRows.content(of: [session], connected: connected).rows]
    }

    @Test func aSessionRowActivatesItsApp() throws {
        for dx in [4, 40, 150, 200] {
            let control = layout.moduleControl(
                at: try point(row: 0, dx: CGFloat(dx)), islandWidth: 808, topHeight: 38, rows: rows(connected: true)
            )
            #expect(control == ModuleControl(module: .claude, row: "session:a", action: .activate), "dx \(dx)")
        }
    }

    @Test func theInvitationOnlyRespondsOnItsButton() throws {
        let rows = rows(connected: false)
        // La fila de la invitación es la segunda; su botón, pegado a la derecha
        let cell = try #require(layout.developerGrid.cells.first { $0.module == .claude })
        let rowWidth = ModuleRowLayout.rowFrame(1, in: cell.frame.size).width
        let button = layout.moduleControl(at: try point(row: 1, dx: rowWidth - 12), islandWidth: 808, topHeight: 38, rows: rows)
        #expect(button == ModuleControl(module: .claude, row: ClaudeRows.connectID, action: .connect))
        let text = layout.moduleControl(at: try point(row: 1, dx: 30), islandWidth: 808, topHeight: 38, rows: rows)
        #expect(text == nil)
    }
}
