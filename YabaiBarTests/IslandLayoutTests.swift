import Foundation
import Testing
@testable import YabaiBar

private func summary(_ index: Int, apps: Int, focused: Bool = false) -> SpaceSummary {
    SpaceSummary(index: index, isFocused: focused,
                 apps: (0..<apps).map { SpaceApp(pid: Int32(index * 1000 + $0), name: "App\($0)") })
}

struct IslandLayoutTests {
    // 12 + 20 de número + 8 hacia el notch, + 6 y 20 por el primer ícono, 24 por cada uno más, 26 por "+n"
    @Test(arguments: [(0, 40.0), (1, 66.0), (2, 90.0), (3, 114.0), (5, 140.0)])
    func leftWingGrowsWithTheActiveSpaceApps(apps: Int, width: Double) {
        #expect(IslandLayout.leftWidth(appCount: apps) == CGFloat(width))
    }

    @Test func splitsActiveToTheLeftAndInactiveToTheRightInOrder() {
        let layout = IslandLayout(spaces: [summary(1, apps: 1), summary(2, apps: 2, focused: true), summary(3, apps: 0), summary(4, apps: 1)])
        #expect(layout.active?.index == 2)
        #expect(layout.inactive.map(\.index) == [1, 3, 4])
    }

    // Lo de ahora: el espacio 2 con 2 apps (90 pt) manda sobre 3 inactivos (8 + 66 + 12 = 86 pt)
    @Test func wingsAreSymmetricAndTakeTheWiderSide() {
        let layout = IslandLayout(spaces: [summary(1, apps: 1), summary(2, apps: 2, focused: true), summary(3, apps: 1), summary(4, apps: 0)])
        #expect(layout.wingWidth == 90)
        #expect(layout.tokenWidth == IslandLayout.tokenWidth)
    }

    @Test func emptyIslandKeepsTheMinimumWidth() {
        #expect(IslandLayout(spaces: []).wingWidth == IslandLayout.minWingWidth)
        #expect(IslandLayout(spaces: [summary(1, apps: 0, focused: true)]).wingWidth == IslandLayout.minWingWidth)
    }

    @Test func manyInactiveSpacesShrinkTheirTokensWithinTheMaximum() {
        let spaces = [summary(1, apps: 1, focused: true)] + (2...10).map { summary($0, apps: 1) }
        let layout = IslandLayout(spaces: spaces)
        #expect(layout.wingWidth == IslandLayout.maxWingWidth)
        #expect(layout.tokenWidth < IslandLayout.tokenWidth)
        #expect(layout.tokenWidth >= IslandLayout.minTokenWidth)
        #expect(CGFloat(layout.inactive.count) * layout.tokenWidth <= layout.wingWidth - IslandLayout.innerPadding - IslandLayout.outerPadding)
    }

    @Test func showsThreeIconsAndCountsTheRest() {
        let layout = IslandLayout(spaces: [summary(1, apps: 5, focused: true)])
        #expect(layout.shownApps.count == 3)
        #expect(layout.overflow == 2)
    }
}

struct SpaceAccentTests {
    @Test(arguments: [(1, 0x8AB4FF as UInt32), (2, 0x7EE787), (10, 0xFF8A80), (11, 0x8AB4FF), (0, 0xFF8A80)])
    func followsTheSketchyBarPaletteAndWraps(index: Int, hex: UInt32) {
        #expect(SpaceAccent.hex(for: index) == hex)
    }
}
