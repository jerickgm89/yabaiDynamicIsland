import Foundation
import Testing
@testable import YabaiBar

// El JSON que cada hook de Claude Code manda por stdin, y el aviso que viaja de `yb` a la app. Los fixtures siguen el formato
// de la documentación de los hooks (no son capturas): el análisis solo mira unos pocos campos y se salta el resto.
struct ClaudeHookTests {
    private func event(_ name: String) throws -> ClaudeHookEvent {
        try #require(ClaudeHookInput.parse(Fixture.data(name)))
    }

    @Test func aPermissionNotificationCarriesItsTypeAndMessage() throws {
        let event = try event("claude-hook-notification-permission")
        #expect(event.name == .notification)
        #expect(event.kind == "permission_prompt")
        #expect(event.message == "Claude needs your permission to use Bash")
        #expect(event.sessionID == "0b6d1a52-7f3c-4c1e-9a55-2f0f6a1d0c01")
        // De la ruta solo viaja el nombre de la carpeta
        #expect(event.cwd == "tienda")
    }

    @Test func onlyTheFolderNameTravels() throws {
        let notice = AvisoMessage(try event("claude-hook-notification-permission"))
        #expect(notice.fields["cwd"] == "tienda")
        #expect(!notice.userInfo.values.contains { $0.contains("/Users") })
    }

    @Test func aToolEventCarriesOnlyTheToolName() throws {
        let ask = try event("claude-hook-pretooluse-ask")
        #expect(ask.name == .preToolUse && ask.kind == "AskUserQuestion" && ask.message.isEmpty)
        let post = try event("claude-hook-posttooluse")
        #expect(post.name == .postToolUse && post.kind == "Bash")
    }

    // Lo que escribes y lo que responde Claude nunca viajan, ni en el evento ni en el aviso
    @Test func promptsAndAnswersNeverTravel() throws {
        for name in ["claude-hook-userpromptsubmit", "claude-hook-stop", "claude-hook-pretooluse-ask", "claude-hook-posttooluse"] {
            let event = try event(name)
            let notice = AvisoMessage(event)
            let everything = notice.userInfo.values.joined(separator: " ") + event.message + event.kind
            #expect(!everything.contains("secreto"), "\(name)")
            #expect(!everything.contains("no debe viajar"), "\(name)")
            #expect(!everything.contains("base de datos"), "\(name)")
            #expect(!everything.contains("README"), "\(name)")
        }
    }

    @Test func stopAndPromptSubmitAreRecognised() throws {
        #expect(try event("claude-hook-stop").name == .stop)
        #expect(try event("claude-hook-userpromptsubmit").name == .userPromptSubmit)
    }

    @Test func unknownOrBrokenInputIsIgnored() {
        let inputs = [
            "", "no es json", "[]", "{}",
            #"{"hook_event_name":"SessionStart","session_id":"x"}"#,
            #"{"hook_event_name":"Stop"}"#,
            #"{"hook_event_name":"Stop","session_id":""}"#,
            #"{"hook_event_name":7,"session_id":"x"}"#,
        ]
        for input in inputs {
            #expect(ClaudeHookInput.parse(Data(input.utf8)) == nil, "\(input)")
        }
        // Un JSON más grande que el límite se descarta sin interpretarlo
        let huge = Data(#"{"hook_event_name":"Stop","session_id":"x","pad":""#.utf8) + Data(repeating: 0x61, count: ClaudeHookInput.maxInputBytes) + Data(#""}"#.utf8)
        #expect(ClaudeHookInput.parse(huge) == nil)
        // La respuesta de una herramienta de varios MB no hace perder el evento
        let big = Data(#"{"hook_event_name":"PostToolUse","session_id":"x","tool_name":"Read","tool_response":""#.utf8)
            + Data(repeating: 0x61, count: 5_000_000) + Data(#""}"#.utf8)
        #expect(ClaudeHookInput.parse(big)?.name == .postToolUse)
    }

    @Test func textIsCleanedAndCut() {
        #expect(ClaudeHookText.clean("a\nb\t\tc\u{0007}d  e") == "a b c d e")
        let long = String(repeating: "x", count: 500)
        let cut = ClaudeHookText.clean(long, limit: 20)
        #expect(cut.count == 20 && cut.hasSuffix("…"))
    }

    // MARK: El aviso entre procesos

    @Test func aNoticeSurvivesTheTripBetweenProcesses() throws {
        let original = try event("claude-hook-notification-permission")
        let notice = AvisoMessage(original)
        let userInfo: [AnyHashable: Any] = notice.userInfo
        let received = try #require(AvisoMessage(userInfo: userInfo))
        #expect(received == notice)
        #expect(received.claudeEvent == original)
    }

    // Lo que llega por la notificación se limpia otra vez en la app: un proceso ajeno puede mandar saltos de línea, caracteres de
    // control o textos largos
    @Test func theAppCleansWhatArrives() throws {
        let hostile = "Línea 1\nlínea 2\u{0007}" + String(repeating: "x", count: 300)
        let notice = try #require(AvisoMessage(userInfo: [
            "kind": "claude-hook", "event": "Notification", "session": "a", "cwd": "/x/\u{202E}web\n", "type": "permission_prompt",
            "message": hostile,
        ]))
        let event = try #require(notice.claudeEvent)
        #expect(!event.message.contains("\n") && !event.message.contains("\u{0007}") && event.message.count <= 160)
        #expect(!event.cwd.contains("\n") && event.cwd.count <= 100)
    }

    // Cualquier proceso puede mandar una notificación con nuestro nombre: lo que no cuadra se descarta
    @Test func malformedNoticesAreRejected() {
        #expect(AvisoMessage(userInfo: nil) == nil)
        #expect(AvisoMessage(userInfo: [:]) == nil)
        #expect(AvisoMessage(userInfo: ["kind": "otra-cosa"]) == nil)
        #expect(AvisoMessage(userInfo: ["kind": 7]) == nil)
        // Un valor que no es texto
        #expect(AvisoMessage(userInfo: ["kind": "claude-hook", "event": 3]) == nil)
        // Demasiados campos
        var many: [AnyHashable: Any] = ["kind": "claude-hook"]
        for index in 0...AvisoMessage.maxFields { many["f\(index)"] = "x" }
        #expect(AvisoMessage(userInfo: many) == nil)
        // Un texto desmesurado
        #expect(AvisoMessage(userInfo: ["kind": "claude-hook", "message": String(repeating: "x", count: 501)]) == nil)
        // Un aviso bien formado de un evento que no existe no es un evento
        let unknown = AvisoMessage(userInfo: ["kind": "claude-hook", "event": "Otro", "session": "x"])
        #expect(unknown != nil && unknown?.claudeEvent == nil)
        let noSession = AvisoMessage(userInfo: ["kind": "claude-hook", "event": "Stop"])
        #expect(noSession?.claudeEvent == nil)
    }
}
