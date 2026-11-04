import Foundation
import Testing
@testable import YabaiBar

struct YabaiClientTests {
    @Test func decodesQueryOutput() async throws {
        let yabai = try FakeYabai.make("cat '\(Fixture.path("spaces"))'")
        let spaces = try await YabaiClient(executablePath: yabai).spaces()
        #expect(spaces == (try JSONDecoder().decode([YabaiSpace].self, from: Fixture.data("spaces"))))
    }

    @Test func missingExecutableIsNotInstalled() async {
        let client = YabaiClient(executablePath: "/nonexistent/yabai")
        await #expect(throws: YabaiError.notInstalled(path: "/nonexistent/yabai")) {
            try await client.spaces()
        }
    }

    @Test func socketErrorMeansNotRunning() async throws {
        let yabai = try FakeYabai.make("echo 'yabai-msg: failed to connect to socket..' >&2; exit 1")
        await #expect(throws: YabaiError.notRunning) {
            try await YabaiClient(executablePath: yabai).windows()
        }
    }

    @Test func otherFailuresKeepStderr() async throws {
        let yabai = try FakeYabai.make("echo 'could not locate space' >&2; exit 1")
        await #expect(throws: YabaiError.commandFailed(command: "yabai -m query --spaces", stderr: "could not locate space")) {
            try await YabaiClient(executablePath: yabai).spaces()
        }
    }

    @Test func invalidJSONIsDecodingError() async throws {
        let yabai = try FakeYabai.make("echo 'no es json'")
        let error = await #expect(throws: YabaiError.self) {
            try await YabaiClient(executablePath: yabai).spaces()
        }
        guard case .decoding = error else {
            Issue.record("Se esperaba .decoding y llegó \(String(describing: error))")
            return
        }
    }

    // `exec` para que el proceso sea el propio sleep: un hijo de sh mantendría abierto el pipe
    @Test func hangingYabaiTimesOut() async throws {
        let yabai = try FakeYabai.make("exec sleep 5")
        let client = YabaiClient(executablePath: yabai, timeout: 0.3)
        let elapsed = await ContinuousClock().measure {
            await #expect(throws: YabaiError.timedOut(command: "yabai -m query --windows")) {
                try await client.windows()
            }
        }
        #expect(elapsed < .seconds(2))
    }
}

struct YabaiSignalsTests {
    @Test func coversTheNineEventsWithTheirLabels() {
        #expect(YabaiSignals.events.count == 9)
        #expect(YabaiSignals.addArguments(for: "window_created")
            == ["--add", "event=window_created", "label=yb_window_created", "action=notifyutil -p com.jerickdev.yabaibar.refresh"])
        #expect(YabaiSignals.removeArguments(for: "space_destroyed") == ["--remove", "yb_space_destroyed"])
    }

    @Test func detectsMissingSignals() {
        let all = YabaiSignals.events.map(YabaiSignals.label(for:))
        #expect(!YabaiSignals.isMissing(from: all + ["otra"]))
        #expect(YabaiSignals.isMissing(from: Array(all.dropLast())))
        #expect(YabaiSignals.isMissing(from: []))
    }

    @Test func addsAtLaunchAndAfterYabaiComesBack() {
        // Al arrancar
        #expect(YabaiSignals.change(enabled: true, failing: false, wasFailing: false, installed: false) == true)
        // Ya están: nada
        #expect(YabaiSignals.change(enabled: true, failing: false, wasFailing: false, installed: true) == nil)
        // yabai falla: no se intenta
        #expect(YabaiSignals.change(enabled: true, failing: true, wasFailing: false, installed: false) == nil)
        // yabai vuelve: quizá se reinició y las perdió
        #expect(YabaiSignals.change(enabled: true, failing: false, wasFailing: true, installed: true) == true)
    }

    @Test func removesOnlyWhenTurnedOffAndInstalled() {
        #expect(YabaiSignals.change(enabled: false, failing: false, wasFailing: false, installed: true) == false)
        #expect(YabaiSignals.change(enabled: false, failing: true, wasFailing: false, installed: true) == false)
        #expect(YabaiSignals.change(enabled: false, failing: false, wasFailing: false, installed: false) == nil)
    }

    @Test func readsSignalLabels() async throws {
        let path = try FakeYabai.make(#"echo '[{"index":0,"label":"yb_window_created","event":"window_created"},{"index":1,"label":"","event":"space_changed"}]'"#)
        let labels = try await YabaiClient(executablePath: path).signalLabels()
        #expect(labels == ["yb_window_created", ""])
    }

    // Llegan a yabai tal cual, con `-m signal` delante
    @Test func reachYabaiAsArguments() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "yabai-args-\(UUID().uuidString)")
        let path = try FakeYabai.make("printf '%s|' \"$@\" >> '\(log.path(percentEncoded: false))'")
        try await YabaiClient(executablePath: path).signal(YabaiSignals.removeArguments(for: "display_added"))
        #expect(try String(contentsOf: log, encoding: .utf8) == "-m|signal|--remove|yb_display_added|")
    }
}
