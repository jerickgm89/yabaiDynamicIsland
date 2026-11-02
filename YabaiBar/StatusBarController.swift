import AppKit
import Observation
import os

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: SpacesStore
    private let renderer: BarRenderer
    private let launchAtLogin: LaunchAtLogin
    private var appearanceObservation: NSKeyValueObservation?
    // Apariencia con la que se dibujó la imagen; nil mientras la barra muestra texto
    private var renderedDark: Bool?

    init(store: SpacesStore, renderer: BarRenderer, launchAtLogin: LaunchAtLogin) {
        self.store = store
        self.renderer = renderer
        self.launchAtLogin = launchAtLogin
        super.init()
        // Cualquier clic abre el menú: para cambiar de espacio se usa el atajo ⌥N de Mission Control
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // La barra pasa de clara a oscura con el modo del sistema o el fondo de escritorio: hay que redibujar
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceChanged() }
        }
        observeStore()
    }

    // KVO avisa también con cada redibujo aunque la apariencia no cambie: sin esta comprobación, bucle infinito
    private func appearanceChanged() {
        guard let button = statusItem.button, let renderedDark, Self.isDark(button) != renderedDark else { return }
        Logger.app.info("La barra pasó a modo \(renderedDark ? "claro" : "oscuro", privacy: .public)")
        render()
    }

    @objc private func refreshFromMenu() {
        store.requestRefresh()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
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
            // El texto lo colorea el sistema: no hace falta redibujarlo al cambiar de apariencia
            renderedDark = nil
            button.image = nil
            button.imagePosition = .noImage
            button.title = description
        } else {
            let dark = Self.isDark(button)
            renderedDark = dark
            let bar = renderer.render(store.spaces, isDark: dark, scale: Self.scale(of: button))
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

extension StatusBarController: NSMenuDelegate {
    // Se rehace cada vez que se abre, para mostrar el error de yabai y el estado de inicio al arrancar
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let error = store.lastError {
            // Sin acción: el menú lo muestra deshabilitado, como un aviso
            menu.addItem(NSMenuItem(title: error.userMessage, action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refrescar", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let available = launchAtLogin.isAvailable
        let login = NSMenuItem(
            title: available ? "Iniciar al arrancar" : "Iniciar al arrancar (instálala en /Applications)",
            action: available ? #selector(toggleLaunchAtLogin) : nil,
            keyEquivalent: ""
        )
        login.target = self
        login.state = available && launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

// Texto para el menú cuando yabai falla
extension YabaiError {
    var userMessage: String {
        switch self {
        case .notInstalled(let path): "No se encuentra yabai en \(path)"
        case .notRunning: "yabai no está en marcha"
        case .timedOut: "yabai no respondió a tiempo"
        case .commandFailed(_, let stderr) where stderr.isEmpty: "yabai devolvió un error"
        case .commandFailed(_, let stderr): "yabai: \(stderr.prefix(80))"
        case .decoding: "No se entendió la respuesta de yabai"
        }
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
