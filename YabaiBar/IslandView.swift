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
    /// La pestaña de la isla abierta que se ve
    var selectedTab = IslandTab.desktops
    /// Las novedades de cada pestaña: un punto en su píldora y su ícono en la isla cerrada
    var tabBadges: [IslandTab: TabBadge] = [:]
    /// Lo que mide el módulo Sistema; nil mientras la pestaña Desarrollador no está a la vista
    var system: SystemSnapshot?
    /// Las filas de los módulos Puertos y Docker, y la fila bajo el puntero (donde se ven sus botones)
    var moduleContent: [ModuleID: ModuleRowsContent] = [:]
    /// Lo que enseña el módulo Calendario
    var calendar: CalendarSnapshot?
    /// Lo que enseña el módulo Portapapeles
    var clipboard: ClipboardSnapshot?
    /// Los archivos de la bandeja, y si se está arrastrando un archivo sobre la isla (la bandeja se resalta)
    var tray: TraySnapshot?
    var trayTargeted = false
    /// Los íconos de los archivos de la bandeja
    @ObservationIgnored let trayIcons = TrayIcons()
    var hoveredRow: String?

    /// Las filas de cada módulo, que es lo que necesitan los clics
    var moduleRows: [ModuleID: [ModuleRow]] { moduleContent.mapValues(\.rows) }

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
    /// Mantener despierto activado: la taza de la isla abierta se enciende
    var keepAwakeActive = false
    /// El Pomodoro, si está activado en Ajustes, con sesión o sin ella; su parte solo se ve en Utilidades, con la isla
    /// abierta y `expanded.hasPomodoro`
    var pomodoro: PomodoroTimer?
    /// Lo que dura un foco: la cuenta atrás del Pomodoro sin sesión, antes de empezar
    var pomodoroFocusDuration: TimeInterval = 25 * 60
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
                // El contenido de cada pestaña se funde con el de la anterior; la isla cambia de tamaño a la vez
                tabContent
                    .padding(.top, IslandExpandedLayout.gapBelowNotch)
                    .id(model.selectedTab)
                    .transition(.opacity)
            }
        }
        .frame(width: model.islandWidth, height: model.islandHeight, alignment: .top)
        // Al cambiar de pestaña, el contenido que sale se desvanece mientras la isla se encoge: sin recorte se vería
        // fuera de la silueta negra
        .clipShape(
            IslandShape(
                topRadius: model.isExpanded ? Self.openTopRadius : Self.closedTopRadius,
                bottomRadius: model.isExpanded ? Self.openBottomRadius : Self.closedBottomRadius
            )
        )
        // Los botones se colocan desde el centro de la isla, como las alas: así no se mueven mientras la isla cambia de
        // ancho al cambiar de pestaña
        .overlay(alignment: .top) {
            if model.isExpanded {
                tabPills
                keepAwakeButton
                settingsButton
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

    // El contenido de la pestaña elegida, debajo de la franja del notch, donde siempre se ven las alas
    @ViewBuilder private var tabContent: some View {
        switch model.selectedTab {
        case .desktops: cards
        case .utilities: utilities
        case .developer: moduleGrid(model.expanded.developerGrid)
        }
    }

    // Utilidades: la fila de la música y el Pomodoro, y debajo la de los módulos
    private var utilities: some View {
        VStack(spacing: IslandExpandedLayout.activityGap) {
            activityRow
            moduleGrid(model.expanded.utilityModules)
        }
    }

    // Desktops: una tarjeta por espacio, que entran escalonadas. Al pasar de una tarjeta a otra vibra el trackpad
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

    // MARK: - La fila de la música y el Pomodoro

    // Las dos partes comparten la fila, separadas por una línea; si solo hay una, ocupa toda la fila. Las posiciones
    // salen de IslandExpandedLayout, que también resuelve los clics (IslandController), así que coinciden siempre
    private var activityRow: some View {
        let layout = model.expanded
        return ZStack(alignment: .topLeading) {
            if let x = layout.dividerX {
                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(width: 1, height: IslandExpandedLayout.activityHeight - 20)
                    .offset(x: x, y: 10)
            }
            if let section = layout.musicSection, let nowPlaying = model.nowPlaying {
                musicPart(nowPlaying, in: section)
            }
            if let section = layout.pomodoroSection, let timer = model.pomodoro {
                pomodoroPart(timer, in: section)
            }
            if !layout.hasActivity {
                Text("No suena nada ahora")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: layout.mediaWidth, height: IslandExpandedLayout.activityHeight)
            }
        }
        .frame(width: layout.mediaWidth, height: IslandExpandedLayout.activityHeight, alignment: .topLeading)
    }

    // MARK: - Los módulos

    // Cada módulo es un recuadro con su título. Los marcos salen de ModuleGridLayout, que se rehace con los módulos que haya
    private func moduleGrid(_ grid: ModuleGridLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.cells, id: \.module) { cell in
                moduleContent(cell.module)
                    .frame(width: cell.frame.width, height: cell.frame.height)
                    .offset(x: cell.frame.minX, y: cell.frame.minY)
            }
        }
        .frame(width: model.expanded.mediaWidth, height: grid.size.height, alignment: .topLeading)
    }

    @ViewBuilder private func moduleContent(_ module: ModuleID) -> some View {
        switch module {
        case .system: systemModule
        case .ports, .docker, .claude, .git, .notices: rowsModule(module)
        case .calendar: calendarModule
        case .clipboard: clipboardModule
        case .tray: trayModule
        }
    }

    private static let moduleShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)

    private func moduleHeader(_ module: ModuleID) -> some View {
        HStack(spacing: 5) {
            Image(systemName: module.symbol).font(.system(size: 11, weight: .semibold))
            Text(module.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(height: ModuleRowLayout.headerHeight)
    }

    // MARK: - Calendario

    // El mes con las flechas, la tira de 7 días, y debajo hasta 2 eventos del día (o «Dar acceso» sin permiso). Los marcos salen de
    // CalendarModuleLayout, que también resuelve los clics
    private var calendarModule: some View {
        let size = model.expanded.utilityModules.cells.first { $0.module == .calendar }?.frame.size ?? CGSize(width: 310, height: IslandExpandedLayout.moduleHeight)
        let snapshot = model.calendar
        let layout = CalendarModuleLayout.self
        return ZStack(alignment: .topLeading) {
            Text(snapshot?.month ?? "")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: layout.headerHeight, alignment: .leading)
                .offset(x: layout.padding, y: layout.padding)
            calendarArrow("chevron.left", .previousWeek, frame: layout.previousFrame(in: size))
            calendarArrow("chevron.right", .nextWeek, frame: layout.nextFrame(in: size))
            ForEach(Array((snapshot?.days ?? []).enumerated()), id: \.element.id) { index, day in
                let frame = layout.dayFrame(index, in: size)
                calendarDay(day, index: index)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            if let snapshot {
                if snapshot.access == .granted {
                    calendarEvents(snapshot, size: size)
                } else {
                    calendarAccessButton(snapshot.access)
                        .frame(width: layout.accessSize.width, height: layout.accessSize.height)
                        .offset(x: layout.accessFrame(in: size).minX, y: layout.accessFrame(in: size).minY)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Self.moduleShape.fill(.white.opacity(0.06)))
    }

    private func calendarArrow(_ symbol: String, _ control: CalendarControl, frame: CGRect) -> some View {
        let hovered = model.hoveredControl == .calendar(control)
        return Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.55))
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(!model.reduceMotion && model.pressedControl == .calendar(control) ? 0.85 : 1)
            .offset(x: frame.minX, y: frame.minY)
    }

    // La inicial del día sobre el número, hoy en azul con su nombre, los fines de semana en otro color y un punto bajo los días
    // con eventos. El elegido lleva un círculo
    private func calendarDay(_ day: CalendarDay, index: Int) -> some View {
        let control = CalendarControl.day(index)
        let hovered = model.hoveredControl == .calendar(control)
        let blue = SpaceAccent.color(for: 1)
        let labelColor: Color = day.isToday ? blue : day.isWeekend ? SpaceAccent.color(for: 3).opacity(0.85) : .white.opacity(0.45)
        return VStack(spacing: 1) {
            Text(day.label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(labelColor)
                .lineLimit(1)
            ZStack {
                Circle()
                    .fill(day.isToday && day.isSelected ? blue : .white.opacity(day.isSelected ? 0.2 : hovered ? 0.1 : 0))
                    .frame(width: 20, height: 20)
                Text("\(day.number)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(day.isToday && day.isSelected ? .white : day.isToday ? blue : .white.opacity(day.isWeekend ? 0.7 : 0.9))
            }
            Circle()
                .fill(.white.opacity(0.7))
                .frame(width: 3.5, height: 3.5)
                .opacity(day.hasEvents ? 1 : 0)
        }
        .scaleEffect(!model.reduceMotion && model.pressedControl == .calendar(control) ? 0.9 : 1)
    }

    // Hasta 2 eventos con la hora, el color de su calendario y el título; el que está en curso, resaltado. Sin ninguno, «Nada para
    // hoy» y lo primero de mañana
    @ViewBuilder private func calendarEvents(_ snapshot: CalendarSnapshot, size: CGSize) -> some View {
        let layout = CalendarModuleLayout.self
        if snapshot.items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.emptyTitle ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                if let next = snapshot.upNext {
                    Text(next.event.isAllDay ? "Mañana · \(next.event.title)" : "Mañana \(next.timeText) · \(next.event.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: size.width - 2 * layout.padding, alignment: .leading)
            .padding(.leading, 6)
            .offset(x: layout.padding, y: layout.eventsY + 2)
        } else {
            ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { index, item in
                let frame = layout.eventFrame(index, in: size)
                calendarEvent(item, index: index)
                    .frame(width: frame.width, height: frame.height, alignment: .leading)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
    }

    private func calendarEvent(_ item: CalendarAgendaItem, index: Int) -> some View {
        let color = item.event.color
        let hovered = model.hoveredControl == .calendar(.event(index)) || model.hoveredControl == .calendar(.join(index))
        return HStack(spacing: 6) {
            Capsule()
                .fill(Color(red: color.red, green: color.green, blue: color.blue))
                .frame(width: 3, height: 14)
            Text(item.timeText)
                .font(.system(size: 10.5, weight: item.isInProgress ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(item.isInProgress ? SpaceAccent.color(for: 1) : .white.opacity(0.55))
            Text(item.event.title)
                .font(.system(size: 11.5, weight: item.isInProgress ? .semibold : .medium))
                .foregroundStyle(.white.opacity(item.isInProgress ? 0.95 : 0.82))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.event.joinURL != nil {
                Text("Unirse")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: CalendarModuleLayout.joinSize.width, height: CalendarModuleLayout.joinSize.height)
                    .background(Capsule().fill(SpaceAccent.color(for: 1).opacity(model.hoveredControl == .calendar(.join(index)) ? 1 : 0.8)))
                    .scaleEffect(!model.reduceMotion && model.pressedControl == .calendar(.join(index)) ? 0.92 : 1)
                    .padding(.trailing, 2)
            }
        }
        .padding(.leading, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(item.isInProgress ? 0.12 : hovered ? 0.07 : 0))
        )
    }

    private func calendarAccessButton(_ access: CalendarAccess) -> some View {
        Text(access == .denied ? "Abrir Ajustes del Sistema" : "Dar acceso")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(SpaceAccent.color(for: 1).opacity(model.hoveredControl == .calendar(.access) ? 1 : 0.8)))
            .scaleEffect(!model.reduceMotion && model.pressedControl == .calendar(.access) ? 0.94 : 1)
    }

    // MARK: - Bandeja

    // Los archivos soltados como íconos en una rejilla de 3 filas; el nombre sale en la cabecera al pasar el puntero y la «×» para
    // quitarlo, en la esquina del ícono. Arrastrando un archivo sobre la isla, el módulo se resalta. Los marcos salen de
    // TrayModuleLayout, que también resuelve los clics
    private var trayModule: some View {
        let size = model.expanded.utilityModules.cells.first { $0.module == .tray }?.frame.size
            ?? CGSize(width: 180, height: IslandExpandedLayout.moduleHeight)
        let layout = TrayModuleLayout.self
        let items = model.tray?.items ?? []
        let shown = Array(items.prefix(layout.slotCount(in: size)))
        let hoveredID: String? = {
            guard case .tray(let control) = model.hoveredControl else { return nil }
            switch control {
            case .item(let id), .remove(let id): return id
            }
        }()
        let accent = SpaceAccent.color(for: 1)
        return ZStack(alignment: .topLeading) {
            trayTitle(items: items, shown: shown.count, hoveredID: hoveredID)
                .frame(width: size.width - 2 * layout.padding, height: layout.headerHeight, alignment: .leading)
                .offset(x: layout.padding, y: layout.padding)
            if items.isEmpty {
                trayEmpty(frame: layout.bodyFrame(in: size))
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { slot, item in
                    trayItem(item, frame: layout.itemFrame(slot, in: size), removeFrame: layout.removeFrame(slot, in: size), hovered: item.id == hoveredID)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Self.moduleShape.fill(model.trayTargeted ? accent.opacity(0.18) : .white.opacity(0.06)))
        .overlay(Self.moduleShape.stroke(accent, lineWidth: model.trayTargeted ? 1.5 : 0))
    }

    // «BANDEJA», o el nombre del archivo bajo el puntero (con «falta» si ya no existe), o la invitación a soltar
    @ViewBuilder private func trayTitle(items: [TraySnapshot.Item], shown: Int, hoveredID: String?) -> some View {
        if model.trayTargeted {
            Text("Suelta para añadir")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SpaceAccent.color(for: 1))
        } else if let item = items.first(where: { $0.id == hoveredID }) {
            Text(item.isMissing ? "\(item.name) · falta" : item.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(item.isMissing ? 0.5 : 0.85))
                .truncationMode(.middle)
        } else {
            HStack(spacing: 5) {
                moduleHeader(.tray)
                if items.count > shown {
                    Text("+\(items.count - shown)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private func trayEmpty(frame: CGRect) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 16, weight: .regular))
            Text("Suelta archivos aquí").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(model.trayTargeted ? 0.9 : 0.5))
        .frame(width: frame.width, height: frame.height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .offset(x: frame.minX, y: frame.minY)
    }

    private func trayItem(_ item: TraySnapshot.Item, frame: CGRect, removeFrame: CGRect, hovered: Bool) -> some View {
        let removing = model.hoveredControl == .tray(.remove(item.id))
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovered ? 0.10 : 0))
            Image(nsImage: model.trayIcons.icon(path: item.path, isMissing: item.isMissing, isVerified: item.isVerified))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .opacity(item.isMissing ? 0.4 : 1)
            if item.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .offset(x: 9, y: 6)
            }
        }
        .frame(width: frame.width, height: frame.height)
        // La «×» va en la esquina del propio ícono, antes de moverlo a su sitio
        .overlay(alignment: .topTrailing) {
            if hovered {
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: removeFrame.width - 1, height: removeFrame.height - 1)
                    .background(Circle().fill(removing ? Color.red.opacity(0.9) : Color.black.opacity(0.65)))
            }
        }
        .scaleEffect(!model.reduceMotion && model.pressedControl == .tray(.item(item.id)) ? 0.92 : 1)
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - Portapapeles

    // La cabecera con sus tres botones (borrar, historial y herramientas) y debajo, según el modo, las 6 últimas copias o las 10
    // herramientas con el cuentagotas y las muestras. Los marcos salen de ClipboardModuleLayout, que también resuelve los clics
    private var clipboardModule: some View {
        let size = model.expanded.utilityModules.cells.first { $0.module == .clipboard }?.frame.size ?? CGSize(width: 250, height: IslandExpandedLayout.moduleHeight)
        let snapshot = model.clipboard
        let layout = ClipboardModuleLayout.self
        let mode = snapshot?.mode ?? .history
        return ZStack(alignment: .topLeading) {
            clipboardTitle(snapshot)
                .frame(width: layout.clearFrame(in: size).minX - layout.padding - 4, height: layout.headerHeight, alignment: .leading)
                .offset(x: layout.padding, y: layout.padding)
            if mode == .history, snapshot?.state == .recording, !(snapshot?.rows.isEmpty ?? true) {
                clipboardIcon("trash", .clear, frame: layout.clearFrame(in: size), active: false)
            }
            clipboardIcon("clock.arrow.circlepath", .mode(.history), frame: layout.historyModeFrame(in: size), active: mode == .history)
            clipboardIcon("wrench.and.screwdriver", .mode(.tools), frame: layout.toolsModeFrame(in: size), active: mode == .tools)
            if let snapshot {
                switch mode {
                case .history: clipboardHistory(snapshot, size: size)
                case .tools: clipboardTools(snapshot, size: size)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Self.moduleShape.fill(.white.opacity(0.06)))
    }

    // El título del módulo, o lo que dice una herramienta al pasar el puntero, o su confirmación o error
    @ViewBuilder private func clipboardTitle(_ snapshot: ClipboardSnapshot?) -> some View {
        if let message = snapshot?.message {
            Text(message.text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(message.isError ? SpaceAccent.color(for: 3) : SpaceAccent.color(for: 2))
                .lineLimit(1)
        } else if case .clipboard(.tool(let tool)) = model.hoveredControl {
            Text(tool.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        } else {
            moduleHeader(.clipboard)
        }
    }

    private func clipboardIcon(_ symbol: String, _ control: ClipboardControl, frame: CGRect, active: Bool) -> some View {
        let hovered = model.hoveredControl == .clipboard(control)
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(active ? 0.95 : hovered ? 0.85 : 0.45))
            .frame(width: frame.width, height: frame.height)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(active ? 0.14 : 0)))
            .scaleEffect(!model.reduceMotion && model.pressedControl == .clipboard(control) ? 0.88 : 1)
            .offset(x: frame.minX, y: frame.minY)
    }

    @ViewBuilder private func clipboardHistory(_ snapshot: ClipboardSnapshot, size: CGSize) -> some View {
        let layout = ClipboardModuleLayout.self
        if snapshot.state == .recording {
            if snapshot.rows.isEmpty {
                Text("Lo que copies saldrá aquí")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: size.width, height: 60)
                    .offset(y: layout.bodyY)
            } else {
                ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                    let frame = layout.entryFrame(index, in: size)
                    let hovered = model.hoveredControl == .clipboard(.entry(index))
                    Text(row.preview)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(width: frame.width, height: frame.height, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovered ? 0.16 : 0.07)))
                        .scaleEffect(!model.reduceMotion && model.pressedControl == .clipboard(.entry(index)) ? 0.96 : 1)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        } else {
            let (text, button): (String, String) = switch snapshot.state {
            case .off, .recording: ("El historial está apagado", "Activar el historial")
            case .needsFirstAccess: ("macOS te preguntará si lo permites", "Dar acceso")
            case .needsAllow: ("Elige «Permitir» para YabaiBar", "Abrir Ajustes del Sistema")
            case .denied: ("Acceso denegado en macOS", "Abrir Ajustes del Sistema")
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: size.width, alignment: .center)
                .offset(y: layout.bodyY + 8)
            Text(button)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: layout.accessSize.width, height: layout.accessSize.height)
                .background(Capsule().fill(SpaceAccent.color(for: 1).opacity(model.hoveredControl == .clipboard(.access) ? 1 : 0.8)))
                .scaleEffect(!model.reduceMotion && model.pressedControl == .clipboard(.access) ? 0.94 : 1)
                .offset(x: layout.accessFrame(in: size).minX, y: layout.accessFrame(in: size).minY)
        }
    }

    @ViewBuilder private func clipboardTools(_ snapshot: ClipboardSnapshot, size: CGSize) -> some View {
        let layout = ClipboardModuleLayout.self
        ForEach(Array(DevTool.allCases.enumerated()), id: \.element) { index, tool in
            let frame = layout.toolFrame(index, in: size)
            let hovered = model.hoveredControl == .clipboard(.tool(tool))
            Text(tool.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
                .frame(width: frame.width, height: frame.height)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovered ? 0.18 : 0.08)))
                .scaleEffect(!model.reduceMotion && model.pressedControl == .clipboard(.tool(tool)) ? 0.92 : 1)
                .offset(x: frame.minX, y: frame.minY)
        }
        let picker = layout.pickerFrame(in: size)
        Image(systemName: "eyedropper")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(model.hoveredControl == .clipboard(.picker) ? 1 : 0.8))
            .frame(width: picker.width, height: picker.height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SpaceAccent.color(for: 1).opacity(model.hoveredControl == .clipboard(.picker) ? 0.6 : 0.35)))
            .scaleEffect(!model.reduceMotion && model.pressedControl == .clipboard(.picker) ? 0.92 : 1)
            .offset(x: picker.minX, y: picker.minY)
        ForEach(Array(snapshot.colors.enumerated()), id: \.element) { index, hex in
            let frame = layout.swatchFrame(index, in: size)
            let color = ColorHex.color(hex) ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5)
            Circle()
                .fill(Color(red: color.red, green: color.green, blue: color.blue))
                .overlay(Circle().stroke(.white.opacity(model.hoveredControl == .clipboard(.swatch(index)) ? 0.9 : 0.35), lineWidth: 1))
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(!model.reduceMotion && model.pressedControl == .clipboard(.swatch(index)) ? 0.85 : 1)
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    // MARK: - Puertos y Docker

    // La cabecera con su resumen («3 abiertos») y hasta 3 filas de 22 pt, o un aviso si no hay nada que enseñar. Los
    // marcos de las filas y de sus botones salen de ModuleRowLayout, que también resuelve los clics
    private func rowsModule(_ module: ModuleID) -> some View {
        let content = model.moduleContent[module]
        let width = model.expanded.developerGrid.cells.first { $0.module == module }?.frame.width ?? 0
        let size = CGSize(width: width, height: IslandExpandedLayout.moduleHeight)
        return ZStack(alignment: .topLeading) {
            HStack {
                moduleHeader(module)
                Spacer(minLength: 4)
                Text(content?.summary ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: size.width - 2 * ModuleRowLayout.padding, height: ModuleRowLayout.headerHeight)
            .offset(x: ModuleRowLayout.padding, y: ModuleRowLayout.padding)
            if let notice = content?.notice {
                VStack(spacing: 3) {
                    Text(notice.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    if let subtitle = notice.subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.66))
                    }
                }
                .multilineTextAlignment(.center)
                .frame(width: size.width - 2 * ModuleRowLayout.padding, height: ModuleRowLayout.rowsHeight)
                .offset(x: ModuleRowLayout.padding, y: ModuleRowLayout.padding + ModuleRowLayout.headerHeight + ModuleRowLayout.headerGap)
            }
            ForEach(Array((content?.rows ?? []).enumerated()), id: \.element.id) { index, row in
                let frame = ModuleRowLayout.rowFrame(index, in: size)
                moduleRow(row, in: module, frame: frame)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Self.moduleShape.fill(.white.opacity(0.06)))
    }

    private func moduleRow(_ row: ModuleRow, in module: ModuleID, frame: CGRect) -> some View {
        let hovered = model.hoveredRow == row.id
        let showsButtons = (hovered || row.showsActionsAlways) && !row.actions.isEmpty
        // Con los botones a la vista, el texto se queda con lo que ellos dejan libre: sin el detalle, que no cabría
        let buttonsWidth = ModuleRowLayout.buttonsWidth(count: row.actions.count) + ModuleRowLayout.buttonInset
        return HStack(spacing: 6) {
            switch row.leading {
            case .none: EmptyView()
            case .code(let text):
                Text(text)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(row.isDimmed ? .white.opacity(0.62) : SpaceAccent.color(for: 1))
                    .frame(width: 44, alignment: .leading)
            case .status(let isOn):
                Circle().fill(isOn ? SpaceAccent.color(for: 2) : .white.opacity(0.4)).frame(width: 6, height: 6)
            case .dot(let tone):
                Circle().fill(Self.toneColor(tone)).frame(width: 6, height: 6)
            }
            Text(row.title)
                .font(.system(size: 11, weight: row.leading == .none ? .medium : .semibold))
                .foregroundStyle(.white.opacity(row.isDimmed ? 0.62 : 0.9))
                .lineLimit(1)
            if !showsButtons {
                Text(row.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !showsButtons, !row.trailing.isEmpty {
                Text(row.trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Self.toneColor(row.tone))
                    .lineLimit(1)
                    .padding(.trailing, 6)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, showsButtons ? buttonsWidth + 4 : 0)
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovered ? 0.1 : 0)))
        .overlay(alignment: .trailing) {
            if showsButtons {
                HStack(spacing: ModuleRowLayout.buttonSpacing) {
                    ForEach(row.actions, id: \.self) { action in
                        rowButton(ModuleControl(module: module, row: row.id, action: action))
                    }
                }
                .padding(.trailing, ModuleRowLayout.buttonInset)
            }
        }
    }

    private static func noticeColor(_ tone: IslandNotice.Tone) -> Color {
        switch tone {
        case .info: SpaceAccent.color(for: 1)
        case .ok: SpaceAccent.color(for: 2)
        case .warning: SpaceAccent.color(for: 3)
        case .error: SpaceAccent.color(for: 10)
        }
    }

    // Azul si algo está en marcha, naranja si espera algo de ti, verde si va bien, rojo si salió mal
    private static func toneColor(_ tone: RowTone) -> Color {
        switch tone {
        case .neutral: .white.opacity(0.4)
        case .active: SpaceAccent.color(for: 1)
        case .attention: SpaceAccent.color(for: 3)
        case .ok: SpaceAccent.color(for: 2)
        case .alert: SpaceAccent.color(for: 10)
        }
    }

    private func rowButton(_ control: ModuleControl) -> some View {
        let hovered = model.hoveredControl == .module(control)
        let pressed = model.pressedControl == .module(control)
        return Image(systemName: control.action.symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(control.action.isDestructive ? SpaceAccent.color(for: 10) : .white.opacity(0.85))
            .frame(width: ModuleRowLayout.buttonSize, height: ModuleRowLayout.buttonSize)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(control.action.isDestructive ? SpaceAccent.color(for: 10).opacity(hovered ? 0.35 : 0.2) : .white.opacity(hovered ? 0.2 : 0.1))
            )
            .scaleEffect(!model.reduceMotion && pressed ? 0.88 : 1)
    }

    // MARK: - Sistema

    // La CPU y la memoria en dos barras y, debajo, los tres procesos que más CPU usan. Mide 14 + 6 + 22 + 6 + 3 × 14 = 90
    // de los 92 pt que deja el recuadro. Hasta la primera medida, rayas
    private var systemModule: some View {
        let snapshot = model.system
        let processes = snapshot?.processes ?? []
        return VStack(alignment: .leading, spacing: 6) {
            moduleHeader(.system)
            HStack(spacing: 12) {
                meter(
                    "CPU", value: snapshot?.cpu.map(SystemFormat.percent) ?? "—", fraction: (snapshot?.cpu ?? 0) / 100,
                    color: SpaceAccent.color(for: 1)
                )
                meter(
                    "RAM", value: snapshot.map { SystemFormat.memory($0.memory) } ?? "—",
                    fraction: snapshot?.memory.usedFraction ?? 0, color: Self.pressureColor(snapshot?.memory.pressure ?? .normal)
                )
            }
            VStack(spacing: 0) {
                ForEach(processes) { process in
                    HStack(spacing: 6) {
                        Text(process.name)
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 4)
                        Text(SystemFormat.percent(process.cpu))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.66))
                    }
                    .font(.system(size: 10.5))
                    .frame(height: 14)
                }
            }
            .frame(height: 42, alignment: .top)
        }
        .padding(10)
        .background(Self.moduleShape.fill(.white.opacity(0.06)))
    }

    // Un nombre, su valor y una barra fina
    private func meter(_ title: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.white.opacity(0.66))
                Spacer(minLength: 0)
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .frame(height: 14)
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                }
        }
        .frame(maxWidth: .infinity)
    }

    // La barra de la memoria cambia de color con la presión que da macOS: verde, naranja y rojo
    private static func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: SpaceAccent.color(for: 2)
        case .warning: SpaceAccent.color(for: 3)
        case .critical: SpaceAccent.color(for: 10)
        }
    }

    // La carátula grande con el ícono de la app en la esquina; el título, el álbum y el artista; los botones y el
    // progreso. Compartiendo la fila, los botones van debajo del texto; sola, a la derecha
    private func musicPart(_ nowPlaying: NowPlaying, in section: CGRect) -> some View {
        let layout = model.expanded
        let cover = IslandExpandedLayout.coverFrame(in: section)
        let textX = IslandExpandedLayout.textX(in: section)
        let controls = layout.controlFrames(IslandExpandedLayout.controls, in: section)
        let shared = layout.sharesActivityRow
        let textEnd = shared ? section.maxX : (controls.first?.frame.minX ?? section.maxX) - 16
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .bottomTrailing) {
                artwork
                    .frame(width: cover.width, height: cover.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // El ícono de la app que suena, en la esquina y dentro de la carátula: así el clic en él también la abre
                if let icon = model.sourceIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                        .padding(2)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black))
                        .padding(3)
                }
            }
            .scaleEffect(controlScale(.artwork))
            .offset(x: cover.minX, y: cover.minY)

            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if !nowPlaying.album.isEmpty {
                    Text(nowPlaying.album)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(nowPlaying.artist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .lineLimit(1)
            .frame(width: max(0, textEnd - textX), alignment: .leading)
            .offset(x: textX, y: section.minY + (shared ? IslandExpandedLayout.sharedTextTop : IslandExpandedLayout.musicTextTop))

            progress(nowPlaying)
                .frame(width: max(0, textEnd - textX))
                .offset(
                    x: textX,
                    y: section.minY + (shared ? IslandExpandedLayout.sharedProgressTop : IslandExpandedLayout.musicProgressTop)
                )

            ForEach(controls.indices, id: \.self) { index in
                let item = controls[index]
                control(item.control, symbol: Self.musicSymbol(item.control, playing: nowPlaying.isPlaying))
                    .offset(x: item.frame.minX, y: item.frame.minY)
            }
        }
    }

    private static func musicSymbol(_ control: IslandExpandedLayout.Control, playing: Bool) -> String {
        switch control {
        case .previous: "backward.fill"
        case .next: "forward.fill"
        default: playing ? "pause.fill" : "play.fill"
        }
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
            } else if case let .claude(peek) = model.peek {
                // Claude pregunta, en naranja, o terminó, en verde
                Image(systemName: peek.kind == .asks ? "sparkles" : "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(peek.kind == .asks ? SpaceAccent.color(for: 3) : SpaceAccent.color(for: 2))
            } else if case let .notice(notice) = model.peek {
                // Un aviso de Git (o de la terminal): su ícono, en el color de su tono
                Image(systemName: notice.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.noticeColor(notice.tone))
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
            } else if case let .claude(peek) = model.peek {
                peekText(peek.title, peek.subtitle)
            } else if case let .notice(notice) = model.peek {
                peekText(notice.title, notice.subtitle)
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

    // Al final del ala derecha: las barras de la música y la taza de mantener despierto
    @ViewBuilder private func statusItem(_ item: IslandLayout.StatusItem) -> some View {
        switch item {
        case .music: musicBars
        case .keepAwake:
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.9))
        case .utilities: tabIndicator(.utilities)
        case .developer: tabIndicator(.developer)
        case .pomodoro: pomodoroRing
        }
    }

    // El ícono de una pestaña con novedades, con su punto de color
    private func tabIndicator(_ tab: IslandTab) -> some View {
        Image(systemName: tab.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .overlay(alignment: .topTrailing) {
                if let badge = model.tabBadges[tab] {
                    Circle()
                        .fill(Self.badgeColor(badge))
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.black, lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }
    }

    static func badgeColor(_ badge: TabBadge) -> Color {
        switch badge {
        case .info: Color(red: 0.30, green: 0.62, blue: 1)
        case .attention: Color(red: 1, green: 0.72, blue: 0.42)
        case .alert: Color(red: 1, green: 0.54, blue: 0.50)
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
                key: "\(timer.phase.rawValue) \(timer.state)",
                animated: !model.reduceMotion
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

    // Lo que hay que mover un botón desde el centro de la isla (arriba y centrada) hasta su marco
    private func cornerOffset(_ frame: CGRect) -> CGFloat {
        frame.midX - model.islandWidth / 2
    }

    // Las píldoras de las pestañas, a la izquierda de las alas, en la franja del notch: solo el ícono, la elegida con fondo.
    // Los clics los resuelve IslandController con IslandExpandedLayout.control, como los de la música
    @ViewBuilder private var tabPills: some View {
        let frames = model.expanded.tabFrames(islandWidth: model.islandWidth, topHeight: model.height)
        ForEach(frames.indices, id: \.self) { index in
            tabPill(frames[index].tab, frame: frames[index].frame)
        }
    }

    private func tabPill(_ tab: IslandTab, frame: CGRect) -> some View {
        let selected = model.selectedTab == tab
        let hovered = model.hoveredControl == .tab(tab)
        return Image(systemName: tab.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(selected ? 1 : hovered ? 0.9 : 0.62))
            .frame(width: frame.width, height: frame.height)
            .background(Circle().fill(.white.opacity(selected ? 0.2 : hovered ? 0.14 : 0)))
            .overlay(alignment: .topTrailing) {
                if let badge = model.tabBadges[tab] {
                    Circle()
                        .fill(Self.badgeColor(badge))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                        .padding(2)
                }
            }
            .scaleEffect(!model.reduceMotion && model.pressedControl == .tab(tab) ? 0.88 : 1)
            .offset(x: cornerOffset(frame), y: frame.minY)
            .transition(.opacity)
    }

    // La taza de la isla abierta, arriba a la derecha junto al engranaje. Los clics los resuelve IslandController
    // con IslandExpandedLayout.control
    @ViewBuilder private var keepAwakeButton: some View {
        if let frame = model.expanded.keepAwakeFrame(islandWidth: model.islandWidth, topHeight: model.height) {
            let hovered = model.hoveredControl == .keepAwake
            Image(systemName: model.keepAwakeActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.keepAwakeActive ? .yellow : .white.opacity(hovered ? 0.9 : 0.55))
                .frame(width: frame.width, height: frame.height)
                .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0)))
                .scaleEffect(!model.reduceMotion && model.pressedControl == .keepAwake ? 0.88 : 1)
                .offset(x: cornerOffset(frame), y: frame.minY)
                .transition(.opacity)
        }
    }

    // El engranaje, arriba a la derecha: abre los ajustes
    @ViewBuilder private var settingsButton: some View {
        if let frame = model.expanded.settingsButtonFrame(islandWidth: model.islandWidth, topHeight: model.height) {
            let hovered = model.hoveredControl == .settings
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.55))
                .frame(width: frame.width, height: frame.height)
                .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0)))
                .scaleEffect(!model.reduceMotion && model.pressedControl == .settings ? 0.88 : 1)
                .offset(x: cornerOffset(frame), y: frame.minY)
                .transition(.opacity)
        }
    }

    // MARK: - Pomodoro

    static let focusColor = Color(red: 1, green: 0.42, blue: 0.33)
    static let breakColor = Color(red: 0.49, green: 0.91, blue: 0.53)

    // El anillo con lo que queda de la fase y, al lado, la fase, la ronda y los de hoy, con ⏯ ⏭ ⏹. El anillo lo anima
    // Core Animation (PomodoroRing); la cuenta atrás se redibuja cada segundo solo mientras corre y la isla está
    // abierta
    private func pomodoroPart(_ timer: PomodoroTimer, in section: CGRect) -> some View {
        let layout = model.expanded
        let ring = IslandExpandedLayout.coverFrame(in: section)
        let textX = IslandExpandedLayout.textX(in: section)
        let controls = layout.controlFrames(layout.pomodoroControlList, in: section)
        let shared = layout.sharesActivityRow
        let textEnd = shared ? section.maxX : (controls.first?.frame.minX ?? section.maxX) - 16
        let color = Self.phaseColor(timer.phase)
        let round = timer.phase == .focus ? timer.completedInRound + 1 : timer.completedInRound
        return TimelineView(.animation(minimumInterval: 1, paused: !timer.isRunning)) { context in
            ZStack(alignment: .topLeading) {
                ZStack {
                    PomodoroRing(
                        progress: timer.progress(at: context.date),
                        remaining: timer.isRunning ? timer.remaining(at: context.date) : nil,
                        color: timer.isRunning ? NSColor(color) : NSColor.white.withAlphaComponent(0.35),
                        key: "\(timer.phase.rawValue) \(timer.state)",
                        lineWidth: 6,
                        animated: !model.reduceMotion
                    )
                    VStack(spacing: 1) {
                        Text(Self.countdown(countdownValue(timer, at: context.date)))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(timer.isRunning ? .white : .white.opacity(0.6))
                        Text(Self.ringCaption(timer))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: ring.width, height: ring.height)
                .offset(x: ring.minX, y: ring.minY)

                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.phase.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                    Text("Ronda \(round) de \(model.pomodoroRounds)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Hoy \(timer.completed(on: context.date)) de \(model.pomodoroGoal)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .lineLimit(1)
                .frame(width: max(0, textEnd - textX), alignment: .leading)
                .offset(
                    x: textX,
                    y: section.minY + (shared ? IslandExpandedLayout.sharedTextTop : IslandExpandedLayout.pomodoroTextTop)
                )

                ForEach(controls.indices, id: \.self) { index in
                    let item = controls[index]
                    control(item.control, symbol: Self.pomodoroSymbol(item.control, running: timer.isRunning))
                        .offset(x: item.frame.minX, y: item.frame.minY)
                }
            }
        }
    }

    // Lo que se ve dentro del anillo: lo que queda de la fase; con la fase lista, lo que dura, y sin sesión, lo que
    // durará el primer foco
    private func countdownValue(_ timer: PomodoroTimer, at date: Date) -> TimeInterval {
        switch timer.state {
        case .stopped: model.pomodoroFocusDuration
        case .ready: timer.phaseDuration
        case .running, .paused: timer.remaining(at: date)
        }
    }

    private static func pomodoroSymbol(_ control: IslandExpandedLayout.Control, running: Bool) -> String {
        switch control {
        case .pomodoroSkip: "forward.end.fill"
        case .pomodoroStop: "stop.fill"
        default: running ? "pause.fill" : "play.fill"
        }
    }

    // Debajo de la cuenta atrás: cuánto dura la fase, o si está en pausa o lista para empezar
    private static func ringCaption(_ timer: PomodoroTimer) -> String {
        switch timer.state {
        case .stopped, .ready: "lista"
        case .paused: "en pausa"
        default: "de \(Int((timer.phaseDuration / 60).rounded())) min"
        }
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
