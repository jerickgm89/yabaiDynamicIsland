import Foundation
import os
import Testing
@testable import YabaiBar

// YabaiQuerying falso: cumple el contrato del real (datos o YabaiError) y cuenta las consultas.
// Cada llamada a spaces() toma la siguiente respuesta; la última se repite.
final class StubYabai: YabaiQuerying {
    struct Response: Sendable {
        var spaces: [YabaiSpace]
        var delay: Duration = .zero
    }

    private let responses: [Response]
    private let windowsResult: Result<[YabaiWindow], YabaiError>
    private let spacesCalls = OSAllocatedUnfairLock(initialState: 0)

    init(_ responses: [Response], windows: Result<[YabaiWindow], YabaiError> = .success([])) {
        self.responses = responses
        self.windowsResult = windows
    }

    var spacesCallCount: Int { spacesCalls.withLock { $0 } }

    func spaces() async throws -> [YabaiSpace] {
        let call = spacesCalls.withLock { count in
            defer { count += 1 }
            return count
        }
        let response = responses[min(call, responses.count - 1)]
        try await Task.sleep(for: response.delay)
        return response.spaces
    }

    func windows() async throws -> [YabaiWindow] {
        try windowsResult.get()
    }
}

@MainActor
struct SpacesStoreTests {
    @Test func refreshPublishesGroupedSpaces() async {
        let spaces = [makeSpace(1), makeSpace(2, focused: true)]
        let windows = [makeWindow(1, pid: 10, app: "Safari", space: 2)]
        let store = SpacesStore(yabai: StubYabai([.init(spaces: spaces)], windows: .success(windows)))

        await store.refresh()

        #expect(store.spaces == SpaceGrouper.group(spaces: spaces, windows: windows))
        #expect(store.lastError == nil)
    }

    @Test func failureClearsSpacesAndKeepsTheError() async {
        let store = SpacesStore(yabai: StubYabai([.init(spaces: [makeSpace(1, focused: true)])], windows: .failure(.notRunning)))

        await store.refresh()

        #expect(store.spaces.isEmpty)
        #expect(store.lastError == .notRunning)
    }

    @Test func requestRefreshCoalescesBursts() async throws {
        let stub = StubYabai([.init(spaces: [makeSpace(1, focused: true)])])
        let store = SpacesStore(yabai: stub, debounce: .milliseconds(50))

        for _ in 0..<5 { store.requestRefresh() }
        try await Task.sleep(for: .milliseconds(400))

        #expect(stub.spacesCallCount == 1)
        #expect(store.spaces.map(\.index) == [1])
    }

    @Test func staleResultIsDiscarded() async throws {
        let slow = StubYabai.Response(spaces: [makeSpace(1, focused: true)], delay: .milliseconds(500))
        let fast = StubYabai.Response(spaces: [makeSpace(1), makeSpace(2, focused: true)])
        let store = SpacesStore(yabai: StubYabai([slow, fast]))

        let first = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        await store.refresh()
        await first.value

        #expect(store.spaces.map(\.index) == [1, 2])
        #expect(store.spaces.first(where: \.isFocused)?.index == 2)
    }
}

struct IslandTitleTests {
    @Test func marksTheFocusedSpaceWithBrackets() {
        let spaces = [1, 2, 3, 4].map { SpaceSummary(index: $0, isFocused: $0 == 3, apps: []) }
        #expect(IslandController.title(for: spaces, failed: false) == "1 2 [3] 4")
    }

    @Test func isNeverEmpty() {
        #expect(IslandController.title(for: [], failed: false) == "YB")
        #expect(IslandController.title(for: [], failed: true) == "YB ⚠︎")
    }
}

struct YabaiErrorMessageTests {
    @Test(arguments: [
        (YabaiError.notInstalled(path: "/usr/local/bin/yabai"), "No se encuentra yabai en /usr/local/bin/yabai"),
        (.notRunning, "yabai no está en marcha"),
        (.timedOut(command: "yabai -m query --spaces"), "yabai no respondió a tiempo"),
        (.commandFailed(command: "yabai -m query --spaces", stderr: ""), "yabai devolvió un error"),
        (.commandFailed(command: "yabai -m query --spaces", stderr: "could not locate space"), "yabai: could not locate space"),
        (.decoding("dataCorrupted"), "No se entendió la respuesta de yabai"),
    ])
    func explainsEachFailureForTheMenu(error: YabaiError, message: String) {
        #expect(error.userMessage == message)
    }

    @Test func truncatesLongErrorOutput() {
        let error = YabaiError.commandFailed(command: "yabai", stderr: String(repeating: "x", count: 500))
        #expect(error.userMessage.count == "yabai: ".count + 80)
    }
}
