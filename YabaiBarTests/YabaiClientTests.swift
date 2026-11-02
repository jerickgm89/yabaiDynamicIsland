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

    @Test func focusPassesIndexAndReportsResult() async throws {
        let argsFile = FileManager.default.temporaryDirectory.appending(path: "fake-yabai-args-\(UUID().uuidString)")
        let succeeding = try FakeYabai.make("echo \"$@\" > '\(argsFile.path(percentEncoded: false))'")
        #expect(await YabaiClient(executablePath: succeeding).focus(space: 3))
        #expect(try String(contentsOf: argsFile, encoding: .utf8) == "-m space --focus 3\n")

        let failing = try FakeYabai.make("exit 1")
        #expect(await YabaiClient(executablePath: failing).focus(space: 3) == false)
    }
}
