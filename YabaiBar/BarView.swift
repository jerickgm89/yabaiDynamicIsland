import SwiftUI

struct BarView: View {
    let layout: BarLayout
    let icons: [Int32: NSImage]
    let foreground: Color

    var body: some View {
        HStack(spacing: BarLayout.slotSpacing) {
            ForEach(layout.slots) { slot in
                HStack(spacing: BarLayout.itemGap) {
                    Text("\(slot.space.index)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(slot.space.isFocused ? Color.orange : foreground)
                        .frame(width: BarLayout.numberWidth)
                    ForEach(slot.shownApps, id: \.pid) { app in
                        Image(nsImage: icons[app.pid] ?? NSImage())
                            .resizable()
                            .frame(width: BarLayout.iconSize, height: BarLayout.iconSize)
                    }
                    if slot.overflow > 0 {
                        Text("+\(slot.overflow)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(foreground.opacity(0.8))
                            .frame(width: BarLayout.overflowWidth)
                    }
                }
                .frame(width: slot.width, height: BarLayout.capsuleHeight)
                .background(slot.space.isFocused ? foreground.opacity(0.15) : .clear, in: Capsule())
            }
        }
        .frame(width: layout.width, height: BarLayout.height)
    }
}

#Preview {
    let app = { (pid: Int32, name: String) in SpaceApp(pid: pid, name: name) }
    let spaces = [
        SpaceSummary(index: 1, isFocused: false, apps: [app(1, "Safari")]),
        SpaceSummary(index: 2, isFocused: true, apps: [app(2, "Xcode"), app(3, "Safari")]),
        SpaceSummary(index: 3, isFocused: false, apps: []),
        SpaceSummary(index: 4, isFocused: false, apps: (4...8).map { app($0, $0.isMultiple(of: 2) ? "Safari" : "Xcode") }),
    ]
    let icons = Dictionary(uniqueKeysWithValues: spaces.flatMap(\.apps).map { app in
        (app.pid, NSWorkspace.shared.icon(forFile: "/Applications/\(app.name).app"))
    })
    BarView(layout: BarLayout(spaces: spaces), icons: icons, foreground: .primary)
        .padding()
}
