import SwiftUI
import Testing
@testable import YabaiBar

// Medidas reales del MacBook Pro 16" del usuario (pantalla de 2056 × 1329 pt)
private let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)
private let notched = NotchGeometry(
    screenFrame: screen,
    topLeftArea: CGRect(x: 0, y: 1291, width: 918, height: 38),
    topRightArea: CGRect(x: 1138, y: 1291, width: 918, height: 38),
    topInset: 38
)

struct NotchGeometryTests {
    @Test func findsTheNotchBetweenTheTwoTopAreas() {
        #expect(notched.hasNotch)
        #expect(notched.notch == CGRect(x: 918, y: 1291, width: 220, height: 38))
        #expect(notched.centerWidth == 224)
    }

    @Test func windowIsCenteredOnTheNotchAndFlushWithTheTop() {
        let frame = notched.windowFrame(wingWidth: 80, topRadius: 6)
        // 224 de cuerpo + 2 × 80 de alas + 2 × 6 de esquinas cóncavas
        #expect(frame == CGRect(x: 830, y: 1291, width: 396, height: 38))
        #expect(frame.midX == notched.notch.midX)
        #expect(frame.maxY == screen.maxY)
    }

    @Test func taller_windowGrowsDownward() {
        let frame = notched.windowFrame(wingWidth: 80, topRadius: 6, height: 150)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.minY == screen.maxY - 150)
    }

    @Test func screenWithoutNotchGetsACenteredFallback() {
        let plain = NotchGeometry(screenFrame: screen, topLeftArea: nil, topRightArea: nil, topInset: 0)
        #expect(!plain.hasNotch)
        #expect(plain.notch.midX == screen.midX)
        #expect(plain.notch.maxY == screen.maxY)
        #expect(plain.notch.size == CGSize(width: NotchGeometry.fallbackNotchWidth, height: NotchGeometry.fallbackHeight))
    }
}

struct IslandShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 396, height: 38)
    private let path = IslandShape(topRadius: 6, bottomRadius: 14).path(in: CGRect(x: 0, y: 0, width: 396, height: 38))

    // Los arcos dejan errores de redondeo del orden de 1e-15: se compara con tolerancia
    @Test func fillsTheWholeFrame() {
        let bounds = path.boundingRect
        #expect(abs(bounds.minX - rect.minX) < 0.001 && abs(bounds.maxX - rect.maxX) < 0.001)
        #expect(abs(bounds.minY - rect.minY) < 0.001 && abs(bounds.maxY - rect.maxY) < 0.001)
    }

    // Arriba ocupa todo el ancho (se funde con el borde de la pantalla) y se curva hacia dentro
    @Test func topCornersFlareOutward() {
        #expect(path.contains(CGPoint(x: 3, y: 0.5)))
        #expect(!path.contains(CGPoint(x: 3, y: 3)))
        #expect(path.contains(CGPoint(x: 393, y: 0.5)))
        #expect(!path.contains(CGPoint(x: 393, y: 3)))
    }

    @Test func bottomCornersAreRounded() {
        #expect(!path.contains(CGPoint(x: 6.5, y: 37.5)))
        #expect(!path.contains(CGPoint(x: 389.5, y: 37.5)))
        #expect(path.contains(CGPoint(x: 198, y: 37.5)))
    }
}
