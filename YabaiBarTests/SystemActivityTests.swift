import Foundation
import Testing
@testable import YabaiBar

private func battery(_ level: Int, plugged: Bool = false) -> BatteryState {
    BatteryState(level: level, isPluggedIn: plugged, isCharging: plugged && level < 100)
}

// #expect no admite llamadas que mutan: cada test pasa una secuencia y compara lo que avisó
private func events(_ sequence: [BatteryState]) -> [BatteryEvent?] {
    var detector = BatteryEventDetector()
    return sequence.map { detector.update($0) }
}

struct BatteryEventDetectorTests {
    // Lo que había al arrancar no avisa
    @Test func theFirstReadingDoesNotCount() {
        #expect(events([battery(5)]) == [nil])
        #expect(events([battery(80, plugged: true)]) == [nil])
    }

    @Test func pluggingAndUnpluggingTheCharger() {
        #expect(events([battery(80), battery(80, plugged: true), battery(81, plugged: true), battery(81)]) == [nil, .pluggedIn, nil, .unplugged])
    }

    // Cada umbral avisa al cruzarlo, una vez, y bajar de golpe del 21 al 9 solo avisa del más grave
    @Test func lowAndCriticalBatteryWarnOnceWhenCrossed() {
        #expect(events([battery(22), battery(21), battery(20), battery(19), battery(11), battery(10), battery(9)])
            == [nil, nil, .low, nil, nil, .critical, nil])
        #expect(events([battery(21), battery(9)]) == [nil, .critical])
    }

    // Enchufada no hay avisos de batería baja, y al volver a bajar del umbral sí
    @Test func noLowWarningsWhilePluggedIn() {
        #expect(events([battery(25, plugged: true), battery(15, plugged: true), battery(30), battery(20)])
            == [nil, nil, .unplugged, .low])
    }
}

private func summary(_ index: Int, apps: Int, focused: Bool = false) -> SpaceSummary {
    SpaceSummary(index: index, isFocused: focused,
                 apps: (0..<apps).map { SpaceApp(pid: Int32(index * 1000 + $0), name: "App\($0)") })
}

struct StatusItemLayoutTests {
    private let spaces = [summary(1, apps: 1, focused: true), summary(2, apps: 1), summary(3, apps: 0), summary(4, apps: 1)]

    // 86 pt de espacios; cada indicador suma 6 de separación y su ancho: música 14, taza 14
    @Test func eachItemWidensTheWings() {
        #expect(IslandLayout(spaces: spaces, statusItems: [.keepAwake]).wingWidth == 106)
        #expect(IslandLayout(spaces: spaces, statusItems: [.music, .keepAwake]).wingWidth == 126)
    }

    // El orden no depende de quién los pida
    @Test func itemsKeepAFixedOrder() {
        #expect(IslandLayout(spaces: spaces, statusItems: [.keepAwake, .music]).statusItems == [.music, .keepAwake])
    }
}

// Cuatro espacios: cuerpo de 580 pt en una isla de 618, con las alas ocupando 400 pt centrados: acaban en
// x = (618 + 400) / 2 = 509. Los botones de 26 pt van a continuación, centrados en la franja del notch de 38 pt (y = 6)
struct KeepAwakeLayoutTests {
    private func layout(spaces count: Int = 4, minBodyWidth: CGFloat = 400) -> IslandExpandedLayout {
        let spaces = (1...count).map { summary($0, apps: 0, focused: $0 == 1) }
        return IslandExpandedLayout(
            spaces: spaces, minBodyWidth: minBodyWidth, maxBodyWidth: 2000, topHeight: 38, hasMedia: true, hasKeepAwake: true
        )
    }

    // Sin engranaje, la taza es el único botón de la derecha y va justo donde acaban las alas
    @Test func theCupSitsNextToTheRightWing() {
        #expect(layout().keepAwakeFrame(islandWidth: 618, topHeight: 38) == CGRect(x: 509, y: 6, width: 26, height: 26))
        #expect(layout().control(at: CGPoint(x: 522, y: 19), islandWidth: 618, topHeight: 38) == .keepAwake)
        // La música no está en la pestaña de los escritorios
        #expect(layout().control(at: CGPoint(x: 570, y: 94), islandWidth: 618, topHeight: 38) == nil)
    }

    // Con pocos espacios, el cuerpo deja sitio al botón a cada lado de las alas
    @Test func makesRoomNextToTheWings() {
        let expected: CGFloat = 364 + 2 * (26 + 14)
        #expect(layout(spaces: 2, minBodyWidth: 364).bodyWidth == expected)
    }

    // Con las tres píldoras a la izquierda (3 × 26 + 2 × 4 = 86) y la taza y el engranaje a la derecha (56), cada
    // lado deja el ancho del mayor, para que las alas sigan centradas
    @Test func theWiderCornerReservesItsWidthOnEachSide() {
        let spaces = [summary(1, apps: 0, focused: true)]
        let layout = IslandExpandedLayout(
            spaces: spaces, minBodyWidth: 364, maxBodyWidth: 2000, topHeight: 38, tabs: IslandTab.allCases,
            hasKeepAwake: true, hasSettingsButton: true
        )
        let expected: CGFloat = 364 + 2 * (86 + 14)
        #expect(layout.bodyWidth == expected)
        // Sin pestañas, solo cuentan la taza y el engranaje (26 + 4 + 26)
        let withoutTabs = IslandExpandedLayout(
            spaces: spaces, minBodyWidth: 364, maxBodyWidth: 2000, topHeight: 38, hasKeepAwake: true, hasSettingsButton: true
        )
        let narrower: CGFloat = 364 + 2 * (56 + 14)
        #expect(withoutTabs.bodyWidth == narrower)
    }

    @Test func theGearSitsNextToTheRightWing() {
        let spaces = (1...4).map { summary($0, apps: 0, focused: $0 == 1) }
        let layout = IslandExpandedLayout(
            spaces: spaces, minBodyWidth: 400, maxBodyWidth: 2000, topHeight: 38, hasSettingsButton: true
        )
        #expect(layout.settingsButtonFrame(islandWidth: 618, topHeight: 38) == CGRect(x: 509, y: 6, width: 26, height: 26))
        #expect(layout.control(at: CGPoint(x: 522, y: 19), islandWidth: 618, topHeight: 38) == .settings)
    }

    @Test func noButtonWhenItIsOff() {
        let spaces = [summary(1, apps: 0, focused: true)]
        let plain = IslandExpandedLayout(spaces: spaces, minBodyWidth: 364, maxBodyWidth: 2000, topHeight: 38)
        #expect(plain.keepAwakeFrame(islandWidth: 402, topHeight: 38) == nil)
        #expect(plain.bodyWidth == 364)
    }
}
