import SwiftUI

// La isla cerrada: ala izquierda con el espacio activo, hueco del notch y ala derecha con los inactivos.
// Como en la Dynamic Island, el contenido de cada ala se pega a su borde exterior.
struct IslandView: View {
    // Radios de la isla cerrada, los mismos que usa Atoll
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14

    let layout: IslandLayout
    let centerWidth: CGFloat
    let icons: [Int32: NSImage]
    /// "YB" o "YB ⚠︎" cuando no hay espacios que mostrar
    let fallbackText: String?

    var body: some View {
        HStack(spacing: 0) {
            leftWing.frame(width: layout.wingWidth)
            Color.clear.frame(width: centerWidth)
            rightWing.frame(width: layout.wingWidth)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, Self.closedTopRadius)
        .background(IslandShape(topRadius: Self.closedTopRadius, bottomRadius: Self.closedBottomRadius).fill(.black))
    }

    private var leftWing: some View {
        HStack(spacing: 0) {
            if let fallbackText {
                Text(fallbackText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else if let active = layout.active {
                Text("\(active.index)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(SpaceAccent.color(for: active.index))
                    .frame(width: IslandLayout.numberWidth)
                HStack(spacing: IslandLayout.iconGap) {
                    ForEach(layout.shownApps, id: \.pid) { app in
                        Image(nsImage: icons[app.pid] ?? NSImage())
                            .resizable()
                            .frame(width: IslandLayout.iconSize, height: IslandLayout.iconSize)
                    }
                }
                .padding(.leading, layout.shownApps.isEmpty ? 0 : IslandLayout.numberGap)
                if layout.overflow > 0 {
                    Text("+\(layout.overflow)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: IslandLayout.overflowWidth)
                        .padding(.leading, IslandLayout.iconGap)
                }
            }
        }
        .padding(.leading, IslandLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rightWing: some View {
        HStack(spacing: 0) {
            ForEach(layout.inactive) { space in
                VStack(spacing: 2) {
                    Text("\(space.index)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white.opacity(space.apps.isEmpty ? 0.32 : 0.78))
                    Circle()
                        .fill(SpaceAccent.color(for: space.index))
                        .frame(width: 4, height: 4)
                        .opacity(space.apps.isEmpty ? 0 : 1)
                }
                .frame(width: layout.tokenWidth)
            }
        }
        .padding(.trailing, IslandLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

#Preview {
    let app = { (pid: Int32) in SpaceApp(pid: pid, name: "App") }
    let layout = IslandLayout(spaces: [
        SpaceSummary(index: 1, isFocused: false, apps: [app(1)]),
        SpaceSummary(index: 2, isFocused: true, apps: [app(2), app(3)]),
        SpaceSummary(index: 3, isFocused: false, apps: [app(4)]),
        SpaceSummary(index: 4, isFocused: false, apps: []),
    ])
    let icon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
    IslandView(layout: layout, centerWidth: 224, icons: [2: icon, 3: icon], fallbackText: nil)
        .frame(width: 224 + 2 * layout.wingWidth + 12, height: 38)
        .padding()
        .background(Color(white: 0.17))
}
