import Foundation

// Geometría pura de la barra: ancho y posición de cada espacio, que BarView usa para dibujar
struct BarLayout: Equatable {
    static let height: CGFloat = 22
    static let capsuleHeight: CGFloat = 20
    static let iconSize: CGFloat = 16
    static let maxIcons = 3
    static let numberWidth: CGFloat = 14
    static let overflowWidth: CGFloat = 14
    static let padding: CGFloat = 4
    static let itemGap: CGFloat = 2
    static let slotSpacing: CGFloat = 4

    struct Slot: Equatable, Identifiable {
        let space: SpaceSummary
        let minX: CGFloat
        let width: CGFloat

        var id: Int { space.index }
        var maxX: CGFloat { minX + width }
        var shownApps: ArraySlice<SpaceApp> { space.apps.prefix(BarLayout.maxIcons) }
        var overflow: Int { max(0, space.apps.count - BarLayout.maxIcons) }
    }

    let slots: [Slot]
    let width: CGFloat

    init(spaces: [SpaceSummary]) {
        var slots: [Slot] = []
        var x: CGFloat = 0
        for space in spaces {
            let width = Self.slotWidth(appCount: space.apps.count)
            slots.append(Slot(space: space, minX: x, width: width))
            x += width + Self.slotSpacing
        }
        self.slots = slots
        self.width = slots.last?.maxX ?? 0
    }

    // Número + íconos visibles (+ "+n" si sobran), separados por itemGap y con padding a cada lado
    static func slotWidth(appCount: Int) -> CGFloat {
        let shown = CGFloat(min(appCount, maxIcons))
        let overflow = appCount > maxIcons ? itemGap + overflowWidth : 0
        return padding * 2 + numberWidth + shown * (itemGap + iconSize) + overflow
    }
}
