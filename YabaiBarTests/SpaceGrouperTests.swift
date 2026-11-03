import Foundation
import Testing
@testable import YabaiBar

func makeSpace(_ index: Int, display: Int = 1, focused: Bool = false) -> YabaiSpace {
    YabaiSpace(id: index + 100, index: index, display: display, windows: [], hasFocus: focused, isVisible: focused)
}

func makeWindow(_ id: Int, pid: Int32, app: String, space: Int, minimized: Bool = false, hidden: Bool = false) -> YabaiWindow {
    YabaiWindow(id: id, pid: pid, app: app, space: space, isMinimized: minimized, isHidden: hidden)
}

struct SpaceGrouperTests {
    @Test func keepsOnlyFocusedDisplaySortedByIndex() {
        let spaces = [makeSpace(3, display: 2), makeSpace(1), makeSpace(4, display: 2, focused: true), makeSpace(2)]
        let result = SpaceGrouper.group(spaces: spaces, windows: [])
        #expect(result.map(\.index) == [3, 4])
        #expect(result.map(\.isFocused) == [false, true])
    }

    @Test func withoutFocusedSpaceUsesTheFirstDisplay() {
        let spaces = [makeSpace(2), makeSpace(1), makeSpace(5, display: 2)]
        #expect(SpaceGrouper.group(spaces: spaces, windows: []).map(\.index) == [1, 2])
    }

    @Test func listsEachAppOnceInOrderOfAppearance() throws {
        let windows = [
            makeWindow(1, pid: 10, app: "Safari", space: 1),
            makeWindow(2, pid: 20, app: "Xcode", space: 1),
            makeWindow(3, pid: 10, app: "Safari", space: 1),
        ]
        let result = SpaceGrouper.group(spaces: [makeSpace(1, focused: true)], windows: windows)
        let first = try #require(result.first)
        #expect(first.apps == [SpaceApp(pid: 10, name: "Safari"), SpaceApp(pid: 20, name: "Xcode")])
    }

    @Test func skipsMinimizedAndHiddenWindows() throws {
        let windows = [
            makeWindow(1, pid: 10, app: "Safari", space: 1, minimized: true),
            makeWindow(2, pid: 20, app: "Notas", space: 1, hidden: true),
            makeWindow(3, pid: 30, app: "Xcode", space: 1),
        ]
        let result = SpaceGrouper.group(spaces: [makeSpace(1, focused: true)], windows: windows)
        #expect(try #require(result.first).apps.map(\.name) == ["Xcode"])
    }

    @Test func keepsEmptySpacesAndSeparatesAppsBySpace() {
        let windows = [makeWindow(1, pid: 10, app: "Safari", space: 1), makeWindow(2, pid: 20, app: "Xcode", space: 3)]
        let spaces = [makeSpace(1, focused: true), makeSpace(2), makeSpace(3)]
        let result = SpaceGrouper.group(spaces: spaces, windows: windows)
        #expect(result.map { $0.apps.map(\.name) } == [["Safari"], [], ["Xcode"]])
    }

    @Test func passesTheFullscreenFlagThrough() {
        var fullscreen = makeSpace(2, focused: true)
        fullscreen.isNativeFullscreen = true
        let result = SpaceGrouper.group(spaces: [makeSpace(1), fullscreen], windows: [])
        #expect(result.map(\.isFullscreen) == [false, true])
    }

    @Test func stripsInvisibleMarksFromAppNames() throws {
        let windows = [makeWindow(1, pid: 10, app: "\u{200E}WhatsApp", space: 1)]
        let result = SpaceGrouper.group(spaces: [makeSpace(1, focused: true)], windows: windows)
        #expect(try #require(result.first).apps.map(\.name) == ["WhatsApp"])
    }

    @Test func emptyInputGivesNoSpaces() {
        #expect(SpaceGrouper.group(spaces: [], windows: []).isEmpty)
    }

    @Test func realFixturesGroupConsistently() throws {
        let spaces = try JSONDecoder().decode([YabaiSpace].self, from: Fixture.data("spaces"))
        let windows = try JSONDecoder().decode([YabaiWindow].self, from: Fixture.data("windows"))
        let result = SpaceGrouper.group(spaces: spaces, windows: windows)
        #expect(!result.isEmpty)
        #expect(result.filter(\.isFocused).count == 1)
        #expect(result.map(\.index) == result.map(\.index).sorted())
        #expect(result.allSatisfy { Set($0.apps.map(\.pid)).count == $0.apps.count })
        #expect(result.flatMap(\.apps).allSatisfy { !$0.name.hasPrefix("\u{200E}") })
    }
}
