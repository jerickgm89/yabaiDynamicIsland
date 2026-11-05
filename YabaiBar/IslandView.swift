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
    /// Lo que suena. La franja solo se ve con la isla abierta y `expanded.hasMedia`
    var nowPlaying: NowPlaying?
    var artwork: NSImage?
    /// El ícono de la app que suena, junto al título
    var sourceIcon: NSImage?
    var hoveredControl: IslandExpandedLayout.Control?
    var pressedControl: IslandExpandedLayout.Control?

    /// Se va a un escritorio desde su tarjeta con su atajo; la del activo solo cierra la isla
    func canSwitch(to space: SpaceSummary) -> Bool {
        space.isFocused || shortcutLabels[space.index] != nil
    }

    /// Se ilumina y se puede pulsar: las que llevan a su escritorio y, del 1 al 9, las que no tienen atajo, que
    /// ofrecen añadirlo
    func canPress(_ space: SpaceSummary) -> Bool {
        canSwitch(to: space) || (!space.isFullscreen && DesktopShortcuts.desktops.contains(space.index))
    }

    /// Ancho de cada ala tal como se ve ahora; con "Reducir movimiento" las alas no se recogen, solo se funden
    var visibleWingWidth: CGFloat {
        if wingsTucked && !reduceMotion { return 0 }
        return peek?.widensWings == true ? IslandLayout.trackPeekWingWidth : layout.wingWidth
    }

    /// Aviso de unos segundos en lugar de los espacios: la canción nueva o la batería
    var peek: IslandPeek?
    /// Mantener despierto activado: el sol de la isla abierta se enciende
    var keepAwakeActive = false
    /// El Pomodoro, si hay sesión; la franja solo se ve con la isla abierta y `expanded.hasPomodoro`
    var pomodoro: PomodoroTimer?
    /// Para el texto de la franja: los focos de cada ronda y el objetivo del día
    var pomodoroRounds = 4
    var pomodoroGoal = 8

    var islandWidth: CGFloat {
        if isExpanded { return expanded.bodyWidth + 2 * IslandView.openTopRadius }
        return centerWidth + 2 * visibleWingWidth + 2 * IslandView.closedTopRadius
            + (hovering ? IslandView.hoverGrowth : 0)
    }

    /// Escala del contenido de las alas: 1 salvo en los notch más bajos (escalas de texto grande)
    var contentScale: CGFloat { IslandLayout.contentScale(forHeight: height) }

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
                if model.expanded.hasPomodoro, let pomodoro = model.pomodoro {
                    pomodoroStrip(pomodoro)
                        .padding(.top, IslandExpandedLayout.pomodoroGap)
                        .transition(.opacity)
                }
                if model.expanded.hasMedia, let nowPlaying = model.nowPlaying {
                    mediaStrip(nowPlaying)
                        .padding(.top, IslandExpandedLayout.mediaGap)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: model.islandWidth, height: model.islandHeight, alignment: .top)
        .overlay(alignment: .topLeading) {
            if model.isExpanded {
                keepAwakeButton
                pomodoroButton
            }
        }
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
                    // Sin "Ir al escritorio N" en Ajustes › Teclado › Atajos no se puede ir con clic. Del 1 al 9,
                    // el clic ofrece añadirlo (DesktopShortcutAssistant); Mission Control no tiene más
                    let canAdd = model.canPress(space)
                    Text(canAdd ? "Añadir atajo" : "Sin atajo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(canAdd ? (hovered ? 0.75 : 0.45) : 0.25))
                }
            }
            HStack(spacing: IslandExpandedLayout.iconSpacing) {
                if space.apps.isEmpty {
                    Text("Vacío")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    // Con muchos espacios en una pantalla estrecha, las tarjetas se estrechan y caben menos íconos
                    let shown = model.expanded.iconsShown(appCount: space.apps.count)
                    ForEach(space.apps.prefix(shown), id: \.pid) { app in
                        Image(nsImage: model.icons[app.pid] ?? NSImage())
                            .resizable()
                            .frame(width: IslandExpandedLayout.iconSize, height: IslandExpandedLayout.iconSize)
                    }
                    if space.apps.count > shown {
                        // Entero aunque se coma parte del margen de la tarjeta: recortado salía "…"
                        Text("+\(space.apps.count - shown)")
                            .fixedSize()
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(height: IslandExpandedLayout.iconSize)
        }
        .padding(IslandExpandedLayout.cardPadding)
        .frame(width: model.expanded.cardWidth, height: IslandExpandedLayout.cardHeight, alignment: .topLeading)
        .background(shape.fill(.white.opacity(hovered ? 0.12 : 0.06)))
        .overlay(shape.strokeBorder(border, lineWidth: 1.5))
        .scaleEffect(cardScale(for: space))
    }

    // MARK: - Ahora suena

    // Carátula, título, artista y progreso, y los botones a la derecha. Los clics los resuelve IslandController
    // con IslandExpandedLayout.mediaControl, igual que los de las tarjetas
    private func mediaStrip(_ nowPlaying: NowPlaying) -> some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: IslandExpandedLayout.artworkSize, height: IslandExpandedLayout.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(controlScale(.artwork))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let icon = model.sourceIcon {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text(nowPlaying.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(nowPlaying.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                progress(nowPlaying)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: IslandExpandedLayout.controlSpacing) {
                control(.previous, symbol: "backward.fill")
                control(.playPause, symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                control(.next, symbol: "forward.fill")
            }
        }
        .frame(width: model.expanded.mediaWidth, height: IslandExpandedLayout.mediaHeight)
    }

    @ViewBuilder private var artwork: some View {
        if let image = model.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // Se redibuja cada segundo solo mientras suena; el tiempo se calcula, no se pregunta a la app
    private func progress(_ nowPlaying: NowPlaying) -> some View {
        TimelineView(.animation(minimumInterval: 1, paused: !nowPlaying.isPlaying)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date)
            HStack(spacing: 6) {
                if let duration = nowPlaying.duration, duration > 0 {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.8)).frame(width: proxy.size.width * elapsed / duration)
                            }
                    }
                    .frame(height: 3)
                    Text("\(Self.time(elapsed)) / \(Self.time(duration))")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                }
            }
            .frame(height: 12)
        }
    }

    private func control(_ control: IslandExpandedLayout.Control, symbol: String) -> some View {
        let hovered = model.hoveredControl == control
        return Image(systemName: symbol)
            .font(.system(size: control == .playPause ? 16 : 12, weight: .semibold))
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: IslandExpandedLayout.controlSize, height: IslandExpandedLayout.controlSize)
            .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0)))
            .scaleEffect(controlScale(control))
    }

    private func controlScale(_ control: IslandExpandedLayout.Control) -> CGFloat {
        !model.reduceMotion && model.pressedControl == control ? 0.88 : 1
    }

    // "3:07"
    private static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // Con "Reducir movimiento" la tarjeta no cambia de tamaño: solo de luz y de borde
    private func cardScale(for space: SpaceSummary) -> CGFloat {
        guard !model.reduceMotion else { return 1 }
        if model.pressedSpace == space.index { return Self.pressedCardScale }
        return model.hoveredSpace == space.index ? Self.hoveredCardScale : 1
    }

    private var leftWing: some View {
        HStack(spacing: 0) {
            if model.peek == .track {
                // Aviso de canción nueva: la carátula y las barras
                artwork
                    .frame(width: IslandLayout.trackPeekArtworkSize, height: IslandLayout.trackPeekArtworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                musicBars.padding(.leading, IslandLayout.musicIndicatorGap)
            } else if case let .battery(event, level) = model.peek {
                Image(systemName: Self.batterySymbol(event, level: level))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.batteryColor(event))
            } else if case let .pomodoro(peek) = model.peek {
                // Aviso del Pomodoro: el símbolo de la fase, en su color
                Image(systemName: peek.phase.isBreak ? "leaf.fill" : "target")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.phaseColor(peek.phase))
            } else if case .shortcuts = model.peek {
                // Atajos de escritorio añadidos
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            } else if let fallbackText = model.fallbackText {
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
        // En los notch bajos el contenido se encoge hacia el borde exterior para caber en el alto
        .scaleEffect(model.contentScale, anchor: .leading)
        .padding(.leading, IslandLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rightWing: some View {
        HStack(spacing: 0) {
            if case let .battery(event, level) = model.peek {
                Text("\(level) %")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Self.batteryColor(event))
            } else if case let .pomodoro(peek) = model.peek {
                peekText(peek.title, peek.subtitle)
            } else if case let .shortcuts(title, subtitle) = model.peek {
                peekText(title, subtitle)
            } else if model.peek == .track, let nowPlaying = model.nowPlaying {
                // Aviso de canción nueva: el título y el artista
                peekText(nowPlaying.title, nowPlaying.artist)
            } else {
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
                ForEach(model.layout.statusItems, id: \.self) { item in
                    statusItem(item)
                        .frame(width: item.width)
                        .padding(.leading, IslandLayout.musicIndicatorGap)
                        .transition(.opacity)
                }
            }
        }
        .scaleEffect(model.contentScale, anchor: .trailing)
        .padding(.trailing, IslandLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // Al final del ala derecha: las barras de la música y el sol de mantener despierto
    @ViewBuilder private func statusItem(_ item: IslandLayout.StatusItem) -> some View {
        switch item {
        case .music: musicBars
        case .keepAwake:
            Image(systemName: "sun.max.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.9))
        case .pomodoro: pomodoroRing
        }
    }

    // Del color de la fase mientras corre; gris en pausa o lista. La animación solo se rehace al empezar, pausar o
    // reanudar (la clave cambia), no en cada redibujo de la isla
    @ViewBuilder private var pomodoroRing: some View {
        if let timer = model.pomodoro {
            let now = Date()
            PomodoroRing(
                progress: timer.progress(at: now),
                remaining: timer.isRunning ? timer.remaining(at: now) : nil,
                color: timer.isRunning ? NSColor(Self.phaseColor(timer.phase)) : NSColor.white.withAlphaComponent(0.35),
                key: "\(timer.phase.rawValue) \(timer.state)"
            )
            .frame(width: IslandLayout.pomodoroRingSize, height: IslandLayout.pomodoroRingSize)
        }
    }

    // El título y el subtítulo de un aviso, recortados al ala
    private func peekText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
        .frame(
            maxWidth: IslandLayout.trackPeekWingWidth - IslandLayout.innerPadding - IslandLayout.outerPadding,
            alignment: .trailing
        )
    }

    // MARK: - Actividades

    // El sol de la isla abierta, arriba a la derecha, en la franja del notch. Los clics los resuelve
    // IslandController con IslandExpandedLayout.control, como los de la música
    @ViewBuilder private var keepAwakeButton: some View {
        if let frame = model.expanded.keepAwakeFrame(islandWidth: model.islandWidth, topHeight: model.height) {
            let hovered = model.hoveredControl == .keepAwake
            Image(systemName: model.keepAwakeActive ? "sun.max.fill" : "sun.max")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.keepAwakeActive ? .yellow : .white.opacity(hovered ? 0.9 : 0.55))
                .frame(width: frame.width, height: frame.height)
                .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0)))
                .scaleEffect(!model.reduceMotion && model.pressedControl == .keepAwake ? 0.88 : 1)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.opacity)
        }
    }

    // MARK: - Pomodoro

    static let focusColor = Color(red: 1, green: 0.42, blue: 0.33)
    static let breakColor = Color(red: 0.49, green: 0.91, blue: 0.53)

    // El botón del Pomodoro, arriba a la izquierda: gris si está parado o en pausa, del color de la fase si corre
    @ViewBuilder private var pomodoroButton: some View {
        if let frame = model.expanded.pomodoroButtonFrame(islandWidth: model.islandWidth, topHeight: model.height) {
            let hovered = model.hoveredControl == .pomodoroToggle
            let timer = model.pomodoro
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(timer?.isRunning == true ? Self.phaseColor(timer?.phase ?? .focus) : .white.opacity(hovered ? 0.9 : 0.55))
                .frame(width: frame.width, height: frame.height)
                .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0)))
                .scaleEffect(!model.reduceMotion && model.pressedControl == .pomodoroToggle ? 0.88 : 1)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.opacity)
        }
    }

    // La fase, la ronda y el progreso a la izquierda; la cuenta atrás y ⏯ ⏭ ⏹ a la derecha. Se redibuja cada
    // segundo solo mientras corre y la isla está abierta
    private func pomodoroStrip(_ timer: PomodoroTimer) -> some View {
        let color = Self.phaseColor(timer.phase)
        return TimelineView(.animation(minimumInterval: 1, paused: !timer.isRunning)) { context in
            HStack(spacing: 10) {
                Image(systemName: timer.phase.isBreak ? "leaf.fill" : "target")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: IslandExpandedLayout.artworkSize)
                VStack(alignment: .leading, spacing: 5) {
                    Text(pomodoroTitle(timer, at: context.date))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(color.opacity(0.9)).frame(width: proxy.size.width * timer.progress(at: context.date))
                            }
                    }
                    .frame(height: 3)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.countdown(timer.state == .ready ? timer.phaseDuration : timer.remaining(at: context.date)))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(timer.isRunning ? .white : .white.opacity(0.5))
                    .fixedSize()
                HStack(spacing: IslandExpandedLayout.controlSpacing) {
                    control(.pomodoroPlayPause, symbol: timer.isRunning ? "pause.fill" : "play.fill")
                    control(.pomodoroSkip, symbol: "forward.end.fill")
                    control(.pomodoroStop, symbol: "stop.fill")
                }
            }
        }
        .frame(width: model.expanded.mediaWidth, height: IslandExpandedLayout.pomodoroHeight)
    }

    // "Foco · 2 de 4 · hoy 3/8", con "en pausa" o "lista para empezar" si toca
    private func pomodoroTitle(_ timer: PomodoroTimer, at date: Date) -> String {
        let round = timer.phase == .focus ? timer.completedInRound + 1 : timer.completedInRound
        var parts = [timer.phase.title, "\(round) de \(model.pomodoroRounds)", "hoy \(timer.completed(on: date))/\(model.pomodoroGoal)"]
        if case .paused = timer.state { parts.append("en pausa") }
        if timer.state == .ready { parts.append("lista") }
        return parts.joined(separator: " · ")
    }

    static func phaseColor(_ phase: PomodoroPhase) -> Color {
        phase.isBreak ? breakColor : focusColor
    }

    // "24:59"
    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private static func batterySymbol(_ event: BatteryEvent, level: Int) -> String {
        switch event {
        case .pluggedIn: "bolt.fill"
        case .critical: "battery.0percent"
        case .low: "battery.25percent"
        case .unplugged:
            switch level {
            case ..<13: "battery.0percent"
            case ..<38: "battery.25percent"
            case ..<63: "battery.50percent"
            case ..<88: "battery.75percent"
            default: "battery.100percent"
            }
        }
    }

    private static func batteryColor(_ event: BatteryEvent) -> Color {
        switch event {
        case .pluggedIn: .green
        case .unplugged: .white
        case .low: .orange
        case .critical: .red
        }
    }

    // Animadas mientras suena; fijas en pausa o con "Reducir movimiento" (ver MusicBars)
    private var musicBars: some View {
        MusicBars(isPlaying: model.nowPlaying?.isPlaying ?? false, animated: !model.reduceMotion)
            .frame(width: IslandLayout.musicIndicatorWidth, height: 12)
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
