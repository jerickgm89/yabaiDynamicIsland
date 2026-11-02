import AppKit
import Observation
import os

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: SpacesStore
    private let renderer: BarRenderer

    init(store: SpacesStore, renderer: BarRenderer) {
        self.store = store
        self.renderer = renderer
        super.init()
        // Cualquier clic abre el menú: para cambiar de espacio se usa el atajo ⌥N de Mission Control
        statusItem.menu = makeMenu()
        observeStore()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refrescar", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func refreshFromMenu() {
        store.requestRefresh()
    }

    // withObservationTracking avisa una sola vez y antes del cambio: se vuelve a registrar en el siguiente ciclo
    private func observeStore() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let failed = store.lastError != nil
        let description = Self.title(for: store.spaces, failed: failed)

        if store.spaces.isEmpty || failed {
            button.image = nil
            button.imagePosition = .noImage
            button.title = description
        } else {
            let bar = renderer.render(store.spaces, isDark: Self.isDark(button), scale: Self.scale(of: button))
            button.title = ""
            button.image = bar.image
            button.imagePosition = .imageOnly
        }
        Logger.app.info("Barra: \(description, privacy: .public)")
    }

    // Texto equivalente a la imagen ("1 2 [3] 4"): se muestra si no hay espacios y se usa en el log
    nonisolated static func title(for spaces: [SpaceSummary], failed: Bool) -> String {
        if failed { return "YB ⚠︎" }
        if spaces.isEmpty { return "YB" }
        return spaces.map { $0.isFocused ? "[\($0.index)]" : "\($0.index)" }.joined(separator: " ")
    }

    private static func isDark(_ button: NSStatusBarButton) -> Bool {
        button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func scale(of button: NSStatusBarButton) -> CGFloat {
        button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

#if DEBUG
extension StatusBarController {
    /// Guarda la barra como PNG ampliado y sobre un fondo como el de la barra, para revisarla sin mirar la pantalla.
    func saveSnapshot() {
        guard let button = statusItem.button, !store.spaces.isEmpty else {
            Logger.app.error("Snapshot: no hay espacios que dibujar")
            return
        }
        let zoom: CGFloat = 4
        let dark = Self.isDark(button)
        let bar = renderer.render(store.spaces, isDark: dark, scale: zoom)
        let size = bar.image.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * zoom), pixelsHigh: Int(size.height * zoom),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: dark ? 0.12 : 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        bar.image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let directory = URL.cachesDirectory.appending(path: "com.jerickdev.yabaibar")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "bar.png"))
            Logger.app.info("Snapshot guardado: \(Int(size.width))×\(Int(size.height)) pt, layout de \(Int(bar.layout.width)) pt")
        } catch {
            Logger.app.error("Snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
