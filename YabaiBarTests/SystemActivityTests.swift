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

    // 86 pt de espacios; cada indicador suma 6 de separación y su ancho: música 14, sol 12
    @Test func eachItemWidensTheWings() {
        #expect(IslandLayout(spaces: spaces, statusItems: [.keepAwake]).wingWidth == 104)
        #expect(IslandLayout(spaces: spaces, statusItems: [.music, .keepAwake]).wingWidth == 124)
    }

    // El orden no depende de quién los pida
    @Test func itemsKeepAFixedOrder() {
        #expect(IslandLayout(spaces: spaces, statusItems: [.keepAwake, .music]).statusItems == [.music, .keepAwake])
    }
}

// Cuatro espacios: cuerpo de 580 pt en una isla de 618; el botón de 26 pt va a 14 del borde derecho del cuerpo
// (x = 559) y centrado en la franja del notch de 38 pt (y = 6)
struct KeepAwakeLayoutTests {
    private func layout(spaces count: Int = 4, minBodyWidth: CGFloat = 400) -> IslandExpandedLayout {
        let spaces = (1...count).map { summary($0, apps: 0, focused: $0 == 1) }
        return IslandExpandedLayout(
            spaces: spaces, minBodyWidth: minBodyWidth, maxBodyWidth: 2000, topHeight: 38, hasMedia: true, hasKeepAwake: true
        )
    }

    @Test func theButtonSitsInTheTopRightCorner() {
        #expect(layout().keepAwakeFrame(islandWidth: 618, topHeight: 38) == CGRect(x: 559, y: 6, width: 26, height: 26))
        #expect(layout().control(at: CGPoint(x: 572, y: 19), islandWidth: 618, topHeight: 38) == .keepAwake)
        // La franja de música sigue respondiendo debajo
        #expect(layout().control(at: CGPoint(x: 570, y: 150), islandWidth: 618, topHeight: 38) == .next)
    }

    // Con pocos espacios, el cuerpo deja sitio al botón a cada lado de las alas
    @Test func makesRoomNextToTheWings() {
        let expected: CGFloat = 364 + 2 * (26 + 14)
        #expect(layout(spaces: 2, minBodyWidth: 364).bodyWidth == expected)
    }

    @Test func noButtonWhenItIsOff() {
        let spaces = [summary(1, apps: 0, focused: true)]
        let plain = IslandExpandedLayout(spaces: spaces, minBodyWidth: 364, maxBodyWidth: 2000, topHeight: 38)
        #expect(plain.keepAwakeFrame(islandWidth: 402, topHeight: 38) == nil)
        #expect(plain.bodyWidth == 364)
    }
}
