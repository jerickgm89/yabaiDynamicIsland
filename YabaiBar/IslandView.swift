import SwiftUI

// Estado que dibuja la isla. IslandController lo cambia dentro de withAnimation para que SwiftUI anime
// los cambios: las alas que se recogen y vuelven a salir al cambiar de escritorio, el hover y la apertura.
@MainActor
@Observable
final class IslandModel {
    var layout = IslandLayout(spaces: [])
    var expanded = IslandExpandedLayout(spaces: [], minBodyWidth: 0, maxBodyWidth: 0, topHeight: 0)
    var centerWidth: CGFloat = 0
    var height: CGFloat = 0
    var icons: [Int32: NSImage] = [:]
    /// "YB" o "YB ⚠︎" cuando no hay espacios que mostrar
    var fallbackText: String? = "YB"
    /// Cambio de escritorio en curso: las alas se recogen hacia el notch mientras cambia el contenido
    var wingsTucked = false
    /// El puntero está encima: la isla crece un poco antes de abrirse
    var hovering = false
    /// Cada vez que cambia, el trackpad vibra (sensoryFeedback)
    var hoverCount = 0
    var isExpanded = false
    var reduceMotion = false
    /// Escritorio de la tarjeta bajo el puntero, con la isla abierta
    var hoveredSpace: Int?
    /// Escritorio de la tarjeta que se está pulsando
    var pressedSpace: Int?
    /// Atajo de Mission Control de cada escritorio ("⌥1"); los que no tienen no aparecen
    var shortcutLabels: [Int: String] = [:]

    /// Se va a un escritorio desde su tarjeta con su atajo; la del activo solo cierra la isla
    func canSwitch(to space: SpaceSummary) -> Bool {
        space.isFocused || shortcutLabels[space.index] != nil
    }

    /// Ancho de cada ala tal como se ve ahora; con "Reducir movimiento" las alas no se recogen, solo se funden
    var visibleWingWidth: CGFloat {
        wingsTucked && !reduceMotion ? 0 : layout.wingWidth
    }

    var islandWidth: CGFloat {
        if isExpanded { return expanded.bodyWidth + 2 * IslandView.openTopRadius }
        return centerWidth + 2 * visibleWingWidth + 2 * IslandView.closedTopRadius
            + (hovering ? IslandView.hoverGrowth : 0)
    }

    var islandHeight: CGFloat {
        if isExpanded { return expanded.height }
        return height + (hovering ? IslandView.hoverGrowth : 0)
    }
}

// La isla cerrada: ala izquierda con el espacio activo, hueco del notch y ala derecha con los inactivos.
// Como en la Dynamic Island, el contenido de cada ala se pega a su borde exterior.
struct IslandView: View {
    // Radios cerrada y abierta, los mismos que usa Atoll
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14
    static let openTopRadius: CGFloat = 19
    static let openBottomRadius: CGFloat = 24
    /// Lo que crece la isla al pasar el puntero, antes de abrirse
    static let hoverGrowth: CGFloat = 8
    /// El número activo se dibuja a 12 pt y se escala, igual que los inactivos
    static let activeNumberScale: CGFloat = 17.0 / 12.0
    // Bajo el puntero, la tarjeta se ilumina, se redondea un poco más y se acerca; al pulsarla, se hunde
    static let cardRadius: CGFloat = 12
    static let hoveredCardRadius: CGFloat = 15
    static let hoveredCardScale: CGFloat = 1.04
    static let pressedCardScale: CGFloat = 0.96

    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing.frame(width: model.visibleWingWidth)
                Color.clear.frame(width: model.centerWidth)
                rightWing.frame(width: model.visibleWingWidth)
            }
            .frame(height: model.height)
            // Recogidas (cambio de escritorio o pantalla completa), las alas se encogen hacia el notch
            // y su contenido se desvanece; al volver a salir, crece y aparece
            .opacity(model.layout.isCollapsed || model.wingsTucked ? 0 : 1)
            .scaleEffect(model.wingsTucked && !model.reduceMotion ? 0.85 : 1)
            if model.isExpanded {
                cards.padding(.top, IslandExpandedLayout.gapBelowNotch)
            }
        }
        .frame(width: model.islandWidth, height: model.islandHeight, alignment: .top)
        .background(
            IslandShape(
                topRadius: model.isExpanded ? Self.openTopRadius : Self.closedTopRadius,
                bottomRadius: model.isExpanded ? Self.openBottomRadius : Self.closedBottomRadius
            )
            .fill(.black)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(model.isExpanded || model.hovering ? 0.6 : 0), radius: model.isExpanded ? 10 : 5)
        .sensoryFeedback(.alignment, trigger: model.hoverCount)
        // La ventana puede ser más grande que la isla (animaciones, sombra): la isla va centrada y pegada
        // arriba. Mínimo 0 para no imponer ningún tamaño a la ventana
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    // Isla abierta: una tarjeta por espacio, que entran escalonadas. Al pasar de una tarjeta a otra vibra el trackpad
    private var cards: some View {
        HStack(spacing: IslandExpandedLayout.cardSpacing) {
            ForEach(model.expanded.spaces) { space in
                let position = model.expanded.spaces.firstIndex(of: space) ?? 0
                card(for: space)
                    .transition(
                        model.reduceMotion
                            ? .opacity
                            : .scale(scale: 0.98, anchor: .top).combined(with: .opacity)
                                .animation(.smooth(duration: 0.25).delay(Double(position) * 0.03))
                    )
            }
        }
        .sensoryFeedback(.alignment, trigger: model.hoveredSpace) { _, hovered in hovered != nil }
    }

    private func card(for space: SpaceSummary) -> some View {
        let accent = SpaceAccent.color(for: space.index)
        let hovered = model.hoveredSpace == space.index
        let shape = RoundedRectangle(cornerRadius: hovered ? Self.hoveredCardRadius : Self.cardRadius, style: .continuous)
        // El activo lleva siempre su color; bajo el puntero, cualquiera lo muestra más suave
        let border = space.isFocused ? accent : hovered ? accent.opacity(0.55) : .clear
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(space.index)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                if let label = model.shortcutLabels[space.index] {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 0.75 : 0.45))
                } else if !space.isFocused {
                    // Sin "Ir al escritorio N" en Ajustes › Teclado › Atajos no se puede ir con clic
                    Text("Sin atajo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            HStack(spacing: 4) {
                if space.apps.isEmpty {
                    Text("Vacío")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    ForEach(space.apps.prefix(IslandExpandedLayout.maxIcons), id: \.pid) { app in
                        Image(nsImage: model.icons[app.pid] ?? NSImage())
                            .resizable()
                            .frame(width: IslandExpandedLayout.iconSize, height: IslandExpandedLayout.iconSize)
                    }
                    if space.apps.count > IslandExpandedLayout.maxIcons {
                        Text("+\(space.apps.count - IslandExpandedLayout.maxIcons)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(height: IslandExpandedLayout.iconSize)
        }
        .padding(10)
        .frame(width: model.expanded.cardWidth, height: IslandExpandedLayout.cardHeight, alignment: .topLeading)
        .background(shape.fill(.white.opacity(hovered ? 0.12 : 0.06)))
        .overlay(shape.strokeBorder(border, lineWidth: 1.5))
        .scaleEffect(cardScale(for: space))
    }

    // Con "Reducir movimiento" la tarjeta no cambia de tamaño: solo de luz y de borde
    private func cardScale(for space: SpaceSummary) -> CGFloat {
        guard !model.reduceMotion else { return 1 }
        if model.pressedSpace == space.index { return Self.pressedCardScale }
        return model.hoveredSpace == space.index ? Self.hoveredCardScale : 1
    }

    private var leftWing: some View {
        HStack(spacing: 0) {
            if let fallbackText = model.fallbackText {
                Text(fallbackText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            } else if let active = model.layout.active {
                number(for: active, isActive: true)
                HStack(spacing: IslandLayout.iconGap) {
                    ForEach(model.layout.shownApps, id: \.pid) { app in
                        let position = model.layout.shownApps.firstIndex(of: app) ?? 0
                        Image(nsImage: model.icons[app.pid] ?? NSImage())
                            .resizable()
                            .frame(width: IslandLayout.iconSize, height: IslandLayout.iconSize)
                            .transition(iconTransition(delay: Double(position) * 0.04))
                    }
                }
                .padding(.leading, model.layout.shownApps.isEmpty ? 0 : IslandLayout.numberGap)
                if model.layout.overflow > 0 {
                    Text("+\(model.layout.overflow)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.numericText())
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
            ForEach(model.layout.inactive) { space in
                VStack(spacing: 2) {
                    number(for: space, isActive: false)
                    Circle()
                        .fill(SpaceAccent.color(for: space.index))
                        .frame(width: 4, height: 4)
                        .opacity(space.apps.isEmpty ? 0 : 1)
                }
                .frame(width: model.layout.tokenWidth)
            }
        }
        .padding(.trailing, IslandLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func number(for space: SpaceSummary, isActive: Bool) -> some View {
        Text("\(space.index)")
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isActive ? SpaceAccent.color(for: space.index) : .white.opacity(space.apps.isEmpty ? 0.32 : 0.78))
            .scaleEffect(isActive ? Self.activeNumberScale : 1)
            .frame(width: isActive ? IslandLayout.numberWidth : model.layout.tokenWidth)
    }

    // Los íconos aparecen difuminándose, uno detrás de otro; con "Reducir movimiento", solo un fundido
    private func iconTransition(delay: Double) -> AnyTransition {
        model.reduceMotion ? .opacity : AnyTransition(.blurReplace).animation(.smooth(duration: 0.25).delay(delay))
    }
}

#Preview {
    let model = IslandModel()
    let app = { (pid: Int32) in SpaceApp(pid: pid, name: "App") }
    model.layout = IslandLayout(spaces: [
        SpaceSummary(index: 1, isFocused: false, apps: [app(1)]),
        SpaceSummary(index: 2, isFocused: true, apps: [app(2), app(3)]),
        SpaceSummary(index: 3, isFocused: false, apps: [app(4)]),
        SpaceSummary(index: 4, isFocused: false, apps: []),
    ])
    model.centerWidth = 224
    model.height = 38
    model.fallbackText = nil
    let icon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
    model.icons = [2: icon, 3: icon]
    return IslandView(model: model)
        .frame(width: model.islandWidth + 16, height: 38)
        .padding()
        .background(Color(white: 0.17))
}
