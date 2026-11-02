import AppKit
import Testing
@testable import YabaiBar

func makeSummary(_ index: Int, apps: Int, focused: Bool = false) -> SpaceSummary {
    SpaceSummary(index: index, isFocused: focused,
                 apps: (0..<apps).map { SpaceApp(pid: Int32(index * 1000 + $0), name: "App\($0)") })
}

struct BarLayoutTests {
    // 22 pt de número y padding, 18 por ícono (máximo 3) y 16 más si hay "+n"
    @Test(arguments: [(0, 22.0), (1, 40.0), (3, 76.0), (5, 92.0)])
    func slotWidthGrowsWithIconsUpToTheLimit(apps: Int, width: Double) {
        #expect(BarLayout.slotWidth(appCount: apps) == CGFloat(width))
    }

    @Test func slotsAreContiguousWithSpacingAndCoverTheWidth() {
        let layout = BarLayout(spaces: [makeSummary(1, apps: 0), makeSummary(2, apps: 2, focused: true), makeSummary(3, apps: 4)])
        #expect(layout.slots.map(\.space.index) == [1, 2, 3])
        #expect(layout.slots.map(\.minX) == [0, 26, 88])
        for (previous, next) in zip(layout.slots, layout.slots.dropFirst()) {
            #expect(next.minX == previous.maxX + BarLayout.slotSpacing)
        }
        #expect(layout.width == 180)
    }

    @Test func overflowShowsThreeIconsAndCountsTheRest() throws {
        let slot = try #require(BarLayout(spaces: [makeSummary(1, apps: 5)]).slots.first)
        #expect(slot.shownApps.count == 3)
        #expect(slot.overflow == 2)
    }

    @Test func emptyBarHasNoSlotsAndNoWidth() {
        let layout = BarLayout(spaces: [])
        #expect(layout.slots.isEmpty)
        #expect(layout.width == 0)
    }
}

@MainActor
struct BarRendererTests {
    // Si la imagen no mide lo mismo que el layout, BarView está recortando o estirando algún espacio
    @Test func imageMatchesTheLayoutSize() {
        let spaces = [makeSummary(1, apps: 0), makeSummary(2, apps: 2, focused: true), makeSummary(3, apps: 4)]
        let bar = BarRenderer().render(spaces, isDark: true, scale: 2)
        #expect(bar.image.size == NSSize(width: bar.layout.width, height: BarLayout.height))
        #expect(bar.image.isTemplate == false)
    }
}
