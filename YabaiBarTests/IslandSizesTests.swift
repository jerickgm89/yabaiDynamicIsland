import CoreGraphics
import Testing
@testable import YabaiBar

// La isla en cualquier MacBook con notch. Apple no publica las medidas del notch y, en puntos, cambian con la escala
// de pantalla: en el 16" del usuario mide 220 × 38 pt con «Más espacio» (2056 de ancho) y unos 185 × 32 con la escala
// por defecto. Así que no se prueban modelos, sino una rejilla de notch y de pantallas que cubre de «Texto más
// grande» a «Más espacio» en los MacBook Air y Pro de 13" a 16".
@MainActor
struct IslandSizesTests {
    static let notchWidths: [CGFloat] = [120, 150, 185, 200, 220, 240]
    static let notchHeights: [CGFloat] = [22, 24, 28, 32, 38, 44]
    static let screenWidths: [CGFloat] = [1024, 1280, 1470, 1512, 1728, 2056, 2560]
    static let spaceCounts = [1, 4, 9]
    /// Por debajo, en una tarjeta solo cabría un ícono
    static let minCardWidth: CGFloat = 88

    // El activo con más apps de las que caben (sale el "+n") y los demás con alguna
    private static func spaces(_ count: Int) -> [SpaceSummary] {
        (1...count).map { index in
            let apps = (0..<(index == 1 ? 6 : 2)).map { SpaceApp(pid: Int32(index * 10 + $0), name: "App \($0)") }
            return SpaceSummary(index: index, isFocused: index == 1, apps: apps)
        }
    }

    private static func geometry(screenWidth: CGFloat, notch: CGSize) -> NotchGeometry {
        NotchGeometry.centered(screen: CGSize(width: screenWidth, height: (screenWidth * 0.65).rounded()), notch: notch)
    }

    private static var everyCase: [(screenWidth: CGFloat, notch: CGSize, spaces: Int)] {
        screenWidths.flatMap { screenWidth in
            notchWidths.flatMap { width in
                notchHeights.flatMap { height in
                    spaceCounts.map { (screenWidth: screenWidth, notch: CGSize(width: width, height: height), spaces: $0) }
                }
            }
        }
    }

    @Test func centeredNotchMatchesTheRealOneOfThe16Inch() {
        let real = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
            topLeftArea: CGRect(x: 0, y: 1291, width: 918, height: 38),
            topRightArea: CGRect(x: 1138, y: 1291, width: 918, height: 38),
            topInset: 38
        )
        #expect(NotchGeometry.centered(screen: CGSize(width: 2056, height: 1329), notch: CGSize(width: 220, height: 38)) == real)
    }

    // Cerrada, con el puntero encima o con el aviso de canción nueva (las alas al máximo), y con su sombra
    @Test func closedIslandStaysOnScreenCenteredOnTheNotch() {
        for (screenWidth, notch, count) in Self.everyCase {
            let geometry = Self.geometry(screenWidth: screenWidth, notch: notch)
            let layout = IslandLayout(spaces: Self.spaces(count), statusItems: IslandLayout.StatusItem.allCases)
            for wing in [layout.wingWidth, IslandLayout.trackPeekWingWidth] {
                let width = geometry.centerWidth + 2 * wing + 2 * IslandView.closedTopRadius
                let frame = geometry.windowFrame(
                    width: width + IslandView.hoverGrowth + 2 * IslandController.shadowMargin, height: notch.height
                )
                #expect(frame.minX >= 0 && frame.maxX <= screenWidth, "\(screenWidth) \(notch) \(count)")
                #expect(frame.midX == geometry.notch.midX)
                #expect(frame.maxY == geometry.notch.maxY)
            }
        }
    }

    // Abierta, con todo (Pomodoro, música y los dos botones de las esquinas): deja 30 pt a cada lado, las tarjetas
    // no bajan de un mínimo y cabe en el lienzo
    @Test func openIslandFitsWithTheAtollMargin() {
        for (screenWidth, notch, count) in Self.everyCase {
            let geometry = Self.geometry(screenWidth: screenWidth, notch: notch)
            let spaces = Self.spaces(count)
            let layout = IslandLayout(spaces: spaces, statusItems: IslandLayout.StatusItem.allCases)
            let expanded = IslandExpandedLayout(
                spaces: spaces, minBodyWidth: geometry.centerWidth + 2 * layout.wingWidth,
                maxBodyWidth: IslandExpandedLayout.maxBodyWidth(screenWidth: screenWidth, topRadius: IslandView.openTopRadius),
                topHeight: notch.height, hasMedia: true, hasKeepAwake: true, hasPomodoro: true, hasPomodoroButton: true
            )
            let islandWidth = expanded.bodyWidth + 2 * IslandView.openTopRadius
            let label = "\(screenWidth) \(notch) \(count)"
            #expect(islandWidth <= screenWidth - 2 * IslandExpandedLayout.screenMargin, "\(label)")
            #expect(expanded.cardWidth >= Self.minCardWidth, "\(label)")
            #expect(expanded.height + IslandController.shadowMargin <= IslandController.canvasHeight, "\(label)")
        }
    }

    // Lo que no cabe en una tarjeta estrecha no se dibuja encima del borde: caben menos íconos
    @Test func narrowCardsShowFewerIcons() {
        typealias Card = IslandExpandedLayout
        // Tarjetas de 132 pt (las de siempre): hasta 4, también con el "+n"
        let wide = Card(spaces: Self.spaces(9), minBodyWidth: 0, maxBodyWidth: 2000, topHeight: 38)
        #expect(wide.cardWidth == Card.cardWidth)
        #expect(wide.iconsShown(appCount: 3) == 3)
        #expect(wide.iconsShown(appCount: 6) == Card.maxIcons)
        // De la pantalla más estrecha de la rejilla (1024 pt) en adelante, con cualquier número de apps
        for maxBody in stride(from: CGFloat(925), through: 1400, by: 5) {
            let expanded = Card(spaces: Self.spaces(9), minBodyWidth: 0, maxBodyWidth: maxBody, topHeight: 38)
            let inside = expanded.cardWidth - 2 * Card.cardPadding
            for apps in 1...8 {
                let shown = expanded.iconsShown(appCount: apps)
                let icons = CGFloat(shown) * Card.iconSize + CGFloat(shown - 1) * Card.iconSpacing
                if shown < apps {
                    // Los íconos y el "+n" (con su separación), comiéndose como mucho parte del margen
                    let row = icons + Card.iconSpacing + Card.overflowWidth
                    #expect(row <= inside + Card.overflowIntoPadding, "\(maxBody) \(apps)")
                    #expect(shown >= 2, "\(maxBody) \(apps)")
                } else {
                    #expect(icons <= inside, "\(maxBody) \(apps)")
                }
            }
        }
    }

    // El contenido de las alas (el aviso de dos líneas es lo más alto) cabe en el alto del notch. Con 30 pt o más,
    // que es lo que dan los MacBook con su escala por defecto, no se toca
    @Test func wingContentFitsTheNotchHeight() {
        for height in Self.notchHeights {
            let scale = IslandLayout.contentScale(forHeight: height)
            #expect(scale * IslandLayout.closedContentHeight <= height - 2, "\(height)")
            #expect(scale * IslandLayout.trackPeekArtworkSize <= height - 2, "\(height)")
            #expect(scale > 0.7, "\(height)")
        }
        #expect(IslandLayout.contentScale(forHeight: 30) == 1)
        #expect(IslandLayout.contentScale(forHeight: 38) == 1)
    }

    // Los botones de las esquinas de la isla abierta caben en la franja del notch
    @Test func cornerButtonsFitTheNotchRow() throws {
        for height in Self.notchHeights {
            let expanded = IslandExpandedLayout(
                spaces: Self.spaces(4), minBodyWidth: 400, maxBodyWidth: 1200, topHeight: height,
                hasKeepAwake: true, hasPomodoroButton: true
            )
            for frame in [
                expanded.keepAwakeFrame(islandWidth: 900, topHeight: height),
                expanded.pomodoroButtonFrame(islandWidth: 900, topHeight: height),
            ] {
                let frame = try #require(frame)
                #expect(frame.minY >= 0 && frame.maxY <= height, "\(height)")
            }
        }
        // En el 16", los de siempre
        #expect(IslandExpandedLayout.cornerButtonSize(topHeight: 38) == IslandExpandedLayout.cornerButtonSize)
    }
}
