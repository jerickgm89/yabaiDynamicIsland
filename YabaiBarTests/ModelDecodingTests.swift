import Foundation
import Testing
@testable import YabaiBar

struct ModelDecodingTests {
    @Test func spaceDecodesHyphenatedKeysAndIgnoresExtraFields() throws {
        let json = """
        [{"id":3,"uuid":"","index":1,"label":"","type":"bsp","display":1,"windows":[10,11],
          "first-window":10,"last-window":11,"has-focus":true,"is-visible":true,"is-native-fullscreen":false}]
        """
        let spaces = try JSONDecoder().decode([YabaiSpace].self, from: Data(json.utf8))
        #expect(spaces == [YabaiSpace(id: 3, index: 1, display: 1, windows: [10, 11], hasFocus: true, isVisible: true)])
    }

    @Test func windowDecodesHyphenatedKeysAndIgnoresExtraFields() throws {
        let json = """
        [{"id":7,"pid":501,"app":"Safari","title":"","space":2,"role":"AXWindow","subrole":"AXStandardWindow",
          "is-minimized":true,"is-hidden":false,"is-sticky":false,"has-focus":false}]
        """
        let windows = try JSONDecoder().decode([YabaiWindow].self, from: Data(json.utf8))
        #expect(windows == [YabaiWindow(id: 7, pid: 501, app: "Safari", space: 2, isMinimized: true, isHidden: false)])
    }

    @Test func realSpacesFixtureHasUniqueIndicesAndOneFocusedSpace() throws {
        let spaces = try JSONDecoder().decode([YabaiSpace].self, from: Fixture.data("spaces"))
        #expect(!spaces.isEmpty)
        #expect(Set(spaces.map(\.index)).count == spaces.count)
        #expect(spaces.filter(\.hasFocus).count == 1)
    }

    @Test func realWindowsFixtureReferencesExistingSpaces() throws {
        let spaces = try JSONDecoder().decode([YabaiSpace].self, from: Fixture.data("spaces"))
        let windows = try JSONDecoder().decode([YabaiWindow].self, from: Fixture.data("windows"))
        let indices = Set(spaces.map(\.index))
        #expect(!windows.isEmpty)
        #expect(windows.allSatisfy { indices.contains($0.space) && $0.pid > 0 })
    }
}
