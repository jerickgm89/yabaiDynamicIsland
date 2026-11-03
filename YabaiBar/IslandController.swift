import AppKit
import Observation
import SwiftUI
import os

// Coloca la isla sobre el notch, la anima cuando cambian los espacios y abre el menú con cualquier clic.
// En reposo la ventana mide justo lo que la isla, para no tapar los clics de SketchyBar alrededor.
@MainActor
final class IslandController {
    // Valores de Atoll para el contenido y para el pulso
    static let changeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let reducedAnimation = Animation.easeInOut(duration: 0.2)
    /// Lo que se espera, tras un cambio, para devolver la ventana a su tamaño justo
    static let settleDelay: Duration = .milliseconds(700)

    private let panel = IslandPanel(contentRect: .zero)
    private let hosting: IslandHostingView
    private let model = IslandModel()
    private let store: SpacesStore
    private let icons: AppIcons
    private var geometry: NotchGeometry?
    // Copia del layout dibujado. No se lee del modelo dentro de render(): withObservationTracking
    // registraría el modelo y cada cambio volvería a llamar a render() sin fin
    private var currentLayout = IslandLayout(spaces: [])
    private var settleTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(store: SpacesStore, icons: AppIcons, menu: AppMenu) {
        self.store = store
        self.icons = icons
        hosting = IslandHostingView(rootView: IslandView(model: model))
        // Que la vista no cambie el tamaño de la ventana: el marco lo decide NotchGeometry
        hosting.sizingOptions = []
        hosting.menuOnClick = menu.menu
        // El hosting va dentro de un contenedor y no como contentView: si lo es, intenta ajustar (y animar)
        // el tamaño de la ventana a la isla, choca con nuestros setFrame y, con cambios de espacio muy
        // seguidos, AppKit lanza una excepción por demasiadas pasadas de restricciones y cierra la app
        let container = NSView()
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

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
        let failed = store.lastError != nil
        apply(spaces: failed ? [] : store.spaces, failed: failed)
    }

    private func apply(spaces: [SpaceSummary], failed: Bool) {
        guard let geometry else { return }
        let layout = IslandLayout(spaces: spaces)
        let previous = currentLayout
        currentLayout = layout
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let activeChanged = previous.active != nil && layout.active?.index != previous.active?.index
        let description = Self.title(for: spaces, failed: failed)

        // La ventana crece antes de animar (con sitio para el pulso) y se ajusta al terminar,
        // para que la isla nunca se recorte a mitad de animación
        let roomyWing = max(layout.wingWidth, previous.wingWidth) + IslandView.pulseGrowth / 2
        panel.setFrame(geometry.windowFrame(wingWidth: roomyWing, topRadius: IslandView.closedTopRadius), display: true)

        withAnimation(reduceMotion ? Self.reducedAnimation : Self.changeAnimation) {
            model.centerWidth = geometry.centerWidth
            model.height = geometry.notch.height
            model.layout = layout
            model.icons = icons.icons(for: spaces)
            model.fallbackText = spaces.isEmpty ? description : nil
            model.reduceMotion = reduceMotion
        }
        if activeChanged && !reduceMotion {
            pulse()
        }
        settleWindow(to: geometry.windowFrame(wingWidth: layout.wingWidth, topRadius: IslandView.closedTopRadius))
        Logger.app.info("Isla: \(description, privacy: .public) (alas de \(Int(layout.wingWidth)) pt)")
    }

    // Como un aviso de la Dynamic Island: la isla crece un instante y vuelve con un rebote
    private func pulse() {
        withAnimation(.bouncy(duration: 0.25)) { model.pulsing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.bouncy(duration: 0.35)) { model.pulsing = false }
        }
    }

    private func settleWindow(to frame: NSRect) {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            panel.setFrame(frame, display: true)
        }
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
    /// Simula cambios de espacio activo muy seguidos, como pasar rápido entre escritorios,
    /// sin tocar los espacios reales. Al terminar vuelve a dibujar el estado real.
    func stressTest(rounds: Int = 40, interval: Duration = .milliseconds(40)) {
        let base = store.spaces
        guard base.count > 1 else { return }
        Task {
            for round in 0..<rounds {
                let focused = base[round % base.count].index
                apply(spaces: base.map { SpaceSummary(index: $0.index, isFocused: $0.index == focused, apps: $0.apps) }, failed: false)
                try? await Task.sleep(for: interval)
            }
            render()
            Logger.app.info("Prueba de estrés terminada: \(rounds) cambios")
        }
    }

    /// Guarda la isla como PNG ampliado y sobre un fondo gris, para revisarla sin mirar la pantalla.
    func saveSnapshot() {
        let size = CGSize(width: model.islandWidth, height: model.height)
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
