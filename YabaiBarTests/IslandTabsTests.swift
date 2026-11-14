import CoreGraphics
import Testing
@testable import YabaiBar

private func space(_ index: Int, focused: Bool = false) -> SpaceSummary {
    SpaceSummary(index: index, isFocused: focused, apps: [SpaceApp(pid: Int32(index), name: "App")])
}

struct IslandTabTests {
    private let all = IslandTab.allCases

    // Desde la última se vuelve a la primera, y desde la primera se pasa a la última
    @Test func steppingWrapsAround() {
        #expect(IslandTab.desktops.stepping(.next, among: all) == .utilities)
        #expect(IslandTab.developer.stepping(.next, among: all) == .desktops)
        #expect(IslandTab.desktops.stepping(.previous, among: all) == .developer)
        #expect(IslandTab.utilities.stepping(.previous, among: all) == .desktops)
    }

    // Con dos pestañas visibles, solo se alterna entre ellas; con una, no hay a dónde ir
    @Test func steppingOnlyVisitsTheVisibleTabs() {
        let visible: [IslandTab] = [.desktops, .developer]
        #expect(IslandTab.desktops.stepping(.next, among: visible) == .developer)
        #expect(IslandTab.developer.stepping(.next, among: visible) == .desktops)
        #expect(IslandTab.desktops.stepping(.next, among: [.desktops]) == .desktops)
        // Una pestaña que ya no está entre las visibles cuenta como la primera
        #expect(IslandTab.utilities.stepping(.next, among: visible) == .developer)
    }

    // Con el puntero se abre para cambiar de escritorio; con el atajo o el gesto, donde se dejó
    @Test func openingWithThePointerAlwaysShowsTheDesktops() {
        #expect(IslandTab.opening(.pointer, last: .developer, among: all) == .desktops)
        #expect(IslandTab.opening(.keyboard, last: .developer, among: all) == .developer)
        #expect(IslandTab.opening(.keyboard, last: .utilities, among: all) == .utilities)
    }

    // h y l, como en vim, solo con el teclado o el gesto: con el puntero no se le quitan esas letras a la app de delante
    @Test func vimKeysOnlyWhenOpenedFromTheKeyboard() {
        #expect(IslandTab.Opening.keyboard.usesVimKeys)
        #expect(!IslandTab.Opening.pointer.usesVimKeys)
    }

    @Test func aHiddenLastTabFallsBackToTheDesktops() {
        #expect(IslandTab.opening(.keyboard, last: .developer, among: [.desktops, .utilities]) == .desktops)
    }

    @Test func everyTabAndModuleHasTitleAndSymbol() {
        for tab in IslandTab.allCases {
            #expect(!tab.title.isEmpty && !tab.symbol.isEmpty)
        }
        for module in ModuleID.allCases {
            #expect(!module.title.isEmpty && !module.symbol.isEmpty)
        }
    }

    @Test func modulesBelongToTheirTab() {
        #expect(ModuleID.modules(of: .utilities) == [.calendar, .clipboard, .tray])
        #expect(ModuleID.modules(of: .developer) == [.system, .ports, .docker, .git, .claude, .notices])
        #expect(ModuleID.modules(of: .desktops).isEmpty)
    }
}

struct ModuleGridLayoutTests {
    private func grid(_ modules: [ModuleID]) -> ModuleGridLayout {
        ModuleGridLayout(modules: modules, columns: 3, width: 730, rowHeight: 112, spacing: 10)
    }

    // 3 columnas de (730 - 2 × 10) / 3 = 236,67 y dos filas de 112 con 10 de hueco: 234 de alto
    @Test func sixModulesFillTwoRowsOfThree() {
        let layout = grid(ModuleID.modules(of: .developer))
        let column: CGFloat = 710.0 / 3
        #expect(layout.size == CGSize(width: 730, height: 234))
        #expect(layout.cells.count == 6)
        #expect(layout.cells[0].frame == CGRect(x: 0, y: 0, width: column, height: 112))
        #expect(abs(layout.cells[2].frame.maxX - 730) < 0.001)
        #expect(layout.cells[3].frame == CGRect(x: 0, y: 122, width: column, height: 112))
        #expect(layout.cells[5].frame.minY == 122)
    }

    // Si se oculta un módulo, los demás ocupan su sitio: el de después sube a su casilla
    @Test func hidingAModuleMakesTheRestMoveUp() {
        let modules = ModuleID.modules(of: .developer).filter { $0 != .ports }
        let layout = grid(modules)
        #expect(layout.cells.map(\.module) == [.system, .docker, .git, .claude, .notices])
        #expect(layout.cells[1].frame == grid(ModuleID.modules(of: .developer)).cells[1].frame)
        // Docker ocupa el sitio de los puertos, y la última fila queda con dos
        #expect(layout.size.height == 234)
        #expect(layout.cells[4].frame.minY == 122)
    }

    // Con tres o menos módulos, una sola fila: la rejilla no deja hueco abajo
    @Test func fewModulesNeedOnlyOneRow() {
        #expect(grid([.system, .ports, .docker]).size.height == 112)
        #expect(grid([.system]).size.height == 112)
        #expect(grid([]).size == CGSize(width: 730, height: 0))
        #expect(grid(ModuleID.modules(of: .developer) + [.calendar]).size.height == 356)
    }

    // Calendario de 310, portapapeles de 250 y la bandeja con lo que sobra de 732 pt
    @Test func theUtilityRowLeavesTheRestToTheTray() {
        let row = ModuleGridLayout(
            row: ModuleID.modules(of: .utilities), fixedWidths: IslandExpandedLayout.utilityRowWidths, width: 732,
            height: 112, spacing: 10
        )
        #expect(row.cells.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 310, height: 112),
            CGRect(x: 320, y: 0, width: 250, height: 112),
            CGRect(x: 580, y: 0, width: 152, height: 112),
        ])
        #expect(row.size == CGSize(width: 732, height: 112))
    }
}

// Con 4 escritorios y un notch de 38 pt, en cada pestaña. Escritorios: cuerpo de 580 (4 tarjetas de 132 y 3 huecos de 8,
// con 14 de margen) y 38 + 8 + 70 + 14 = 130 de alto. Utilidades: 760 de cuerpo y 38 + 8 + 96 + 10 + 112 + 14 = 278.
// Desarrollador: 770 y 38 + 8 + (2 × 112 + 10) + 14 = 294
@MainActor
struct IslandTabSizesTests {
    private func layout(
        _ tab: IslandTab, tabs: [IslandTab] = IslandTab.allCases, maxBodyWidth: CGFloat = 1958,
        developerModules: [ModuleID] = ModuleID.modules(of: .developer), topHeight: CGFloat = 38
    ) -> IslandExpandedLayout {
        IslandExpandedLayout(
            spaces: (1...4).map { space($0, focused: $0 == 1) }, minBodyWidth: 396, maxBodyWidth: maxBodyWidth,
            topHeight: topHeight, tab: tab, tabs: tabs, developerModules: developerModules, hasMedia: true,
            hasKeepAwake: true, hasPomodoro: true, hasSettingsButton: true
        )
    }

    @Test func eachTabHasItsOwnSize() {
        // Con las tres píldoras, cada lado deja 3 × 26 + 2 × 4 = 86: 396 + 2 × (86 + 14) = 596, más que las 4 tarjetas
        // (580), así que manda lo que piden las alas y los botones
        #expect(layout(.desktops).bodyWidth == 596)
        #expect(layout(.desktops).height == 130)
        #expect(layout(.utilities).bodyWidth == 760)
        #expect(layout(.utilities).height == 278)
        #expect(layout(.developer).bodyWidth == 770)
        #expect(layout(.developer).height == 294)
    }

    // En una pantalla estrecha el cuerpo se queda en lo que cabe, pero nunca por debajo de lo que piden las alas y los botones
    @Test func narrowScreensClampTheBodyAboveTheMinimum() {
        #expect(layout(.developer, maxBodyWidth: 700).bodyWidth == 700)
        #expect(layout(.developer, maxBodyWidth: 400).bodyWidth == 596)
    }

    @Test func hidingDeveloperModulesShrinksTheTab() {
        #expect(layout(.developer, developerModules: Array(ModuleID.modules(of: .developer).prefix(3))).height == 172)
        #expect(layout(.developer, developerModules: Array(ModuleID.modules(of: .developer).prefix(5))).height == 294)
        #expect(layout(.developer, developerModules: []).height == 60)
    }

    // Con una sola pestaña no hay píldoras, y el cuerpo solo guarda sitio a los botones de la derecha
    @Test func aSingleTabHasNoPills() {
        let single = layout(.desktops, tabs: [.desktops])
        #expect(single.tabFrames(islandWidth: 618, topHeight: 38).isEmpty)
        #expect(single.control(at: CGPoint(x: 46, y: 19), islandWidth: 618, topHeight: 38) == nil)
        // 396 + 2 × (56 + 14) = 536, y las tarjetas piden 580
        #expect(single.bodyWidth == 580)
    }

    // Isla de 596 + 38 = 634 con las tres píldoras. La franja de las alas (396) va centrada y empieza en
    // x = (634 - 396) / 2 = 119; las píldoras ocupan los 86 pt anteriores: x = 33, 63 y 93, y = 6
    @Test func theTabPillsSitNextToTheWings() {
        let frames = layout(.desktops).tabFrames(islandWidth: 634, topHeight: 38)
        #expect(frames.map(\.tab) == IslandTab.allCases)
        #expect(frames.map(\.frame) == [
            CGRect(x: 33, y: 6, width: 26, height: 26),
            CGRect(x: 63, y: 6, width: 26, height: 26),
            CGRect(x: 93, y: 6, width: 26, height: 26),
        ])
    }

    // El centro de la píldora número i está a (island - 396) / 2 - 86 + 30 i + 13 del borde izquierdo, en cualquier pestaña
    @Test(arguments: [(0, IslandTab.desktops), (1, .utilities), (2, .developer)])
    func clickingAPillSelectsItsTab(index: Int, tab: IslandTab) {
        for current in IslandTab.allCases {
            let layout = layout(current)
            let island = layout.bodyWidth + 2 * IslandView.openTopRadius
            let x = (island - 396) / 2 - 73 + CGFloat(30 * index)
            #expect(layout.control(at: CGPoint(x: x, y: 19), islandWidth: island, topHeight: 38) == .tab(tab))
        }
    }

    // Lo que importa al usuario: cambiar de pestaña no mueve las píldoras ni los botones de la derecha por la pantalla,
    // así que se puede pulsar una tras otra sin seguirlas. Se mide desde el centro de la isla, que no se mueve:
    // las píldoras a -271, -241 y -211 (= -396 / 2 - 86 + 13 + 30 i), la taza a 211 y el engranaje a 241
    @Test func pillsAndButtonsDoNotMoveBetweenTabs() throws {
        for current in IslandTab.allCases {
            let layout = layout(current)
            let island = layout.bodyWidth + 2 * IslandView.openTopRadius
            let pills = layout.tabFrames(islandWidth: island, topHeight: 38).map { $0.frame.midX - island / 2 }
            #expect(pills == [-271, -241, -211], "\(current)")
            let cup = try #require(layout.keepAwakeFrame(islandWidth: island, topHeight: 38))
            let gear = try #require(layout.settingsButtonFrame(islandWidth: island, topHeight: 38))
            #expect(cup.midX - island / 2 == 211, "\(current)")
            #expect(gear.midX - island / 2 == 241, "\(current)")
        }
    }

    // Las alas acaban en x = (634 + 396) / 2 = 515; el grupo de la derecha (26 + 4 + 26 = 56) va a continuación: la taza
    // en x = 515 y el engranaje en x = 545
    @Test func theCupAndTheGearSitNextToTheWings() {
        let desktops = layout(.desktops)
        #expect(desktops.keepAwakeFrame(islandWidth: 634, topHeight: 38) == CGRect(x: 515, y: 6, width: 26, height: 26))
        #expect(desktops.settingsButtonFrame(islandWidth: 634, topHeight: 38) == CGRect(x: 545, y: 6, width: 26, height: 26))
        #expect(desktops.control(at: CGPoint(x: 528, y: 19), islandWidth: 634, topHeight: 38) == .keepAwake)
        #expect(desktops.control(at: CGPoint(x: 558, y: 19), islandWidth: 634, topHeight: 38) == .settings)
    }

    // Lo que no se ve en la pestaña elegida no responde: un clic donde estarían las tarjetas, la música o el Pomodoro
    // en otra pestaña no cambia de escritorio ni toca nada
    @Test func hiddenContentDoesNotRespond() {
        let desktops = layout(.desktops)
        let utilities = layout(.utilities)
        let developer = layout(.developer)
        func island(_ layout: IslandExpandedLayout) -> CGFloat { layout.bodyWidth + 2 * IslandView.openTopRadius }
        // Las tarjetas, solo en la suya: con 4 espacios la fila empieza en x = (634 - 552) / 2 = 41
        #expect(desktops.cardIndex(at: CGPoint(x: 100, y: 60), islandWidth: island(desktops), topHeight: 38) == 0)
        #expect(utilities.cardIndex(at: CGPoint(x: 100, y: 60), islandWidth: island(utilities), topHeight: 38) == nil)
        #expect(developer.cardIndex(at: CGPoint(x: 100, y: 60), islandWidth: island(developer), topHeight: 38) == nil)
        // La música y el Pomodoro, solo en Utilidades
        for tab in [desktops, developer] {
            #expect(tab.musicSection == nil && tab.pomodoroSection == nil)
            for spot in [CGPoint(x: 100, y: 90), CGPoint(x: 300, y: 90), CGPoint(x: 500, y: 90), CGPoint(x: 700, y: 90)] {
                #expect(tab.control(at: spot, islandWidth: island(tab), topHeight: 38) == nil)
                #expect(!tab.musicContains(spot, islandWidth: island(tab), topHeight: 38))
            }
        }
        #expect(utilities.musicSection != nil && utilities.pomodoroSection != nil)
    }

    // La fila de la música y el Pomodoro es lo primero de Utilidades: y = 38 + 8 = 46
    @Test func theActivityRowStartsRightBelowTheNotchStrip() {
        let utilities = layout(.utilities)
        let origin = utilities.activityOrigin(islandWidth: 798, topHeight: 38)
        #expect(origin == CGPoint(x: 33, y: 46))
        #expect(utilities.mediaWidth == 732)
    }

    // Sin sesión de Pomodoro, su parte solo tiene el botón de empezar
    @Test func anIdlePomodoroOnlyHasThePlayButton() throws {
        let idle = IslandExpandedLayout(
            spaces: (1...4).map { space($0, focused: $0 == 1) }, minBodyWidth: 396, maxBodyWidth: 1958, topHeight: 38,
            tab: .utilities, hasPomodoro: true, pomodoroIdle: true
        )
        #expect(idle.pomodoroControlList == [.pomodoroPlayPause])
        let section = try #require(idle.pomodoroSection)
        let play = try #require(idle.controlFrames(idle.pomodoroControlList, in: section).first)
        // Sola en la fila de 732 pt, el botón va a la derecha (x = 732 - 30) y centrado en alto (y = (96 - 30) / 2)
        #expect(play.frame == CGRect(x: 702, y: 33, width: 30, height: 30))
        let centre = CGPoint(x: 33 + play.frame.midX, y: 46 + play.frame.midY)
        #expect(idle.control(at: centre, islandWidth: 798, topHeight: 38) == .pomodoroPlayPause)
        // Los de saltar y parar no están
        #expect(idle.control(at: CGPoint(x: centre.x - 36, y: centre.y), islandWidth: 798, topHeight: 38) == nil)
    }
}

struct DeveloperBadgeTests {
    // El naranja de Claude, que espera, manda sobre la novedad de Git; sin ninguno de los dos no hay punto
    @Test func claudeWaitingBeatsGitNews() {
        #expect(TabBadge.developer(claudeWaiting: 0, news: nil) == nil)
        #expect(TabBadge.developer(claudeWaiting: 1, news: nil) == .attention)
        #expect(TabBadge.developer(claudeWaiting: 0, news: .alert) == .alert)
        #expect(TabBadge.developer(claudeWaiting: 0, news: .info) == .info)
        #expect(TabBadge.developer(claudeWaiting: 2, news: .alert) == .attention)
    }
}

struct TabBadgeStatusItemTests {
    private let spaces = [space(1, focused: true), space(2)]

    // Los indicadores van siempre en el mismo orden, con el Pomodoro al borde
    @Test func tabIndicatorsComeBeforeThePomodoroRing() {
        let layout = IslandLayout(spaces: spaces, statusItems: [.pomodoro, .developer, .music, .utilities, .keepAwake])
        #expect(layout.statusItems == [.music, .keepAwake, .utilities, .developer, .pomodoro])
        #expect(IslandLayout.StatusItem.utilities.tab == .utilities)
        #expect(IslandLayout.StatusItem.developer.tab == .developer)
        #expect(IslandLayout.StatusItem.music.tab == nil)
    }

    // Cada indicador ocupa su sitio en el ala derecha: el ala se ensancha, hasta su máximo
    @Test func aTabIndicatorWidensTheRightWing() {
        let plain = IslandLayout(spaces: [space(1, focused: true)] + (2...4).map { space($0) })
        let marked = IslandLayout(spaces: [space(1, focused: true)] + (2...4).map { space($0) }, statusItems: [.developer])
        let extra = IslandLayout.musicIndicatorGap + IslandLayout.tabIndicatorWidth
        #expect(marked.wingWidth == min(plain.wingWidth + extra, IslandLayout.maxWingWidth))
    }

    @Test func noIndicatorsWhenFullscreen() {
        var fullscreen = space(1, focused: true)
        fullscreen.isFullscreen = true
        #expect(IslandLayout(spaces: [fullscreen], statusItems: [.developer, .utilities]).statusItems.isEmpty)
    }
}
