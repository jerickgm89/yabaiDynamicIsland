import AppKit
import SwiftUI
import os

// Crea la ventana de la isla y la coloca sobre el notch. En la fase 9 sustituye a StatusBarController.
@MainActor
final class IslandController {
    // Fase 8: alas fijas; en la fase 9 las calcula IslandLayout según los espacios
    static let wingWidth: CGFloat = 80

    private let panel = IslandPanel(contentRect: .zero)
    private var screenObserver: NSObjectProtocol?

    init() {
        let hosting = NSHostingView(rootView: IslandView())
        // Que la vista no cambie el tamaño de la ventana: el marco lo decide NotchGeometry
        hosting.sizingOptions = []
        panel.contentView = hosting
        // Fase 8: sin interacción, los clics pasan a lo que haya debajo
        panel.ignoresMouseEvents = true
        place()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func place() {
        guard let screen = Self.notchScreen() else { return }
        let geometry = NotchGeometry(
            screenFrame: screen.frame,
            topLeftArea: screen.auxiliaryTopLeftArea,
            topRightArea: screen.auxiliaryTopRightArea,
            topInset: screen.safeAreaInsets.top
        )
        let frame = geometry.windowFrame(wingWidth: Self.wingWidth, topRadius: IslandView.closedTopRadius)
        panel.setFrame(frame, display: true)
        Logger.app.info("""
            Isla: notch \(String(describing: geometry.notch), privacy: .public) \
            (\(geometry.hasNotch ? "real" : "supuesto", privacy: .public)), ventana \(String(describing: frame), privacy: .public)
            """)
    }

    // La pantalla integrada con notch; si no hay ninguna, la principal
    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}
