import AppKit
import Observation
import SwiftUI
import os

// Coloca la isla sobre el notch, la redibuja cuando cambian los espacios y abre el menú con cualquier clic.
// La ventana mide justo lo que la isla, para no tapar los clics de SketchyBar alrededor.
@MainActor
final class IslandController {
    private let panel = IslandPanel(contentRect: .zero)
    private let hosting: IslandHostingView
    private let store: SpacesStore
    private let icons: AppIcons
    private var geometry: NotchGeometry?
    private var screenObserver: NSObjectProtocol?

    init(store: SpacesStore, icons: AppIcons, menu: AppMenu) {
        self.store = store
        self.icons = icons
        hosting = IslandHostingView(rootView: IslandView(layout: IslandLayout(spaces: []), centerWidth: 0, icons: [:], fallbackText: nil))
        // Que la vista no cambie el tamaño de la ventana: el marco lo decide NotchGeometry
        hosting.sizingOptions = []
        hosting.menuOnClick = menu.menu
        panel.contentView = hosting

        updateGeometry()
        observeStore()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateGeometry()
                self?.render()
            }
        }
    }

    // withObservationTracking avisa una sola vez y antes del cambio: se vuelve a registrar en el siguiente ciclo
    private func observeStore() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func updateGeometry() {
        guard let screen = Self.notchScreen() else { return }
        geometry = NotchGeometry(
            screenFrame: screen.frame,
            topLeftArea: screen.auxiliaryTopLeftArea,
            topRightArea: screen.auxiliaryTopRightArea,
            topInset: screen.safeAreaInsets.top
        )
    }

    private func render() {
        guard let geometry else { return }
        let failed = store.lastError != nil
        let spaces = failed ? [] : store.spaces
        let layout = IslandLayout(spaces: spaces)
        let description = Self.title(for: spaces, failed: failed)

        hosting.rootView = IslandView(
            layout: layout,
            centerWidth: geometry.centerWidth,
            icons: icons.icons(for: spaces),
            fallbackText: spaces.isEmpty ? description : nil
        )
        panel.setFrame(geometry.windowFrame(wingWidth: layout.wingWidth, topRadius: IslandView.closedTopRadius), display: true)
        Logger.app.info("Isla: \(description, privacy: .public) (alas de \(Int(layout.wingWidth)) pt)")
    }

    // Texto equivalente a la isla ("1 [2] 3 4"): se muestra si no hay espacios y se usa en el log
    nonisolated static func title(for spaces: [SpaceSummary], failed: Bool) -> String {
        if failed { return "YB ⚠︎" }
        if spaces.isEmpty { return "YB" }
        return spaces.map { $0.isFocused ? "[\($0.index)]" : "\($0.index)" }.joined(separator: " ")
    }

    // La pantalla integrada con notch; si no hay ninguna, la principal
    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

// Cualquier clic sobre la isla abre el menú de la app
final class IslandHostingView: NSHostingView<IslandView> {
    var menuOnClick: NSMenu?

    // La isla vive en un panel que nunca se activa: el primer clic tiene que llegar igualmente
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { showMenu(for: event) }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    private func showMenu(for event: NSEvent) {
        guard let menuOnClick else { return }
        NSMenu.popUpContextMenu(menuOnClick, with: event, for: self)
    }
}

#if DEBUG
extension IslandController {
    /// Guarda la isla como PNG ampliado y sobre un fondo gris, para revisarla sin mirar la pantalla.
    func saveSnapshot() {
        let size = panel.frame.size
        let content = hosting.rootView
            .frame(width: size.width, height: size.height)
            .padding(16)
            .background(Color(white: 0.17))
        let zoom: CGFloat = 4
        let renderer = ImageRenderer(content: content)
        renderer.scale = zoom
        // Se dibuja en un mapa de bits RGB de 8 bits: guardar directamente la salida de ImageRenderer
        // (en un espacio de color extendido) dejaba los colores apagados en el PNG
        guard let image = renderer.nsImage,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * zoom), pixelsHigh: Int(image.size.height * zoom),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else {
            Logger.app.error("Snapshot: no se pudo dibujar la isla")
            return
        }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = URL.cachesDirectory.appending(path: "com.jerickdev.yabaibar")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appending(path: "bar.png"))
            Logger.app.info("Snapshot guardado: isla de \(Int(size.width))×\(Int(size.height)) pt")
        } catch {
            Logger.app.error("Snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
