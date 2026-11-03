import AppKit
import Observation
import SwiftUI
import os

// Coloca la isla sobre el notch, la anima cuando cambian los espacios y abre el menú con cualquier clic.
// En reposo la ventana mide justo lo que la isla, para no tapar los clics de la barra de menús alrededor.
@MainActor
final class IslandController {
    // Valores de Atoll para el contenido, el hover, la apertura y el cierre
    static let changeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let hoverAnimation = Animation.bouncy.speed(1.2)
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 1.0)
    static let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let reducedAnimation = Animation.easeInOut(duration: 0.2)
    /// Lo que se espera, tras un cambio, para devolver la ventana a su tamaño justo
    static let settleDelay: Duration = .milliseconds(700)
    /// Lo que tiene que estar el puntero encima para que la isla se abra
    static let openDelay: Duration = .milliseconds(300)
    static let pointerCheckInterval: Duration = .milliseconds(120)
    /// Margen de la ventana alrededor de la isla para que quepa la sombra
    static let shadowMargin: CGFloat = 16

    private enum Expansion { case closed, peek, open }

    /// Alto del lienzo de la isla: cabe la isla abierta con su sombra
    static let canvasHeight: CGFloat = 220

    private let panel = IslandPanel(contentRect: .zero)
    private let container = IslandContainerView()
    private let hosting: IslandHostingView
    private let model = IslandModel()
    private let store: SpacesStore
    private let icons: AppIcons
    private var geometry: NotchGeometry?
    private var screenWidth: CGFloat = 0
    // Copias de lo dibujado. No se leen del modelo dentro de render(): withObservationTracking
    // registraría el modelo y cada cambio volvería a llamar a render() sin fin
    private var currentLayout = IslandLayout(spaces: [])
    private var currentSpaces: [SpaceSummary] = []
    private var expansion = Expansion.closed
    private var settleTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var pointerWatch: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(store: SpacesStore, icons: AppIcons, menu: AppMenu) {
        self.store = store
        self.icons = icons
        hosting = IslandHostingView(rootView: IslandView(model: model))
        // Que la vista no cambie el tamaño de la ventana: el marco lo decide NotchGeometry
        hosting.sizingOptions = []
        hosting.menuOnClick = menu.menu
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        // El hosting va dentro de un contenedor y no como contentView: si lo es, intenta ajustar (y animar)
        // el tamaño de la ventana a la isla, choca con nuestros setFrame y, con cambios de espacio muy
        // seguidos, AppKit lanza una excepción por demasiadas pasadas de restricciones y cierra la app
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
        screenWidth = screen.frame.width
        container.canvasSize = CGSize(width: screen.frame.width, height: Self.canvasHeight)
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
        currentSpaces = spaces
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let activeChanged = previous.active != nil && layout.active?.index != previous.active?.index
        let description = Self.title(for: spaces, failed: failed)

        // La ventana crece antes de animar y se ajusta al terminar, para que la isla nunca se recorte
        growWindow()
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.changeAnimation) {
            model.centerWidth = geometry.centerWidth
            model.height = geometry.notch.height
            model.layout = layout
            model.expanded = expandedLayout(for: spaces, geometry: geometry)
            model.icons = icons.icons(for: spaces)
            model.fallbackText = spaces.isEmpty ? description : nil
            model.reduceMotion = reduceMotion
        }
        if activeChanged && !reduceMotion {
            pulse()
        }
        settleWindow()
        Logger.app.info("Isla: \(description, privacy: .public) (alas de \(Int(layout.wingWidth)) pt)")
    }

    private func expandedLayout(for spaces: [SpaceSummary], geometry: NotchGeometry) -> IslandExpandedLayout {
        IslandExpandedLayout(
            spaces: spaces,
            minBodyWidth: geometry.centerWidth + 2 * currentLayout.wingWidth,
            // Como en Atoll, la isla abierta deja al menos 30 pt libres a cada lado de la pantalla
            maxBodyWidth: screenWidth - 60 - 2 * IslandView.openTopRadius,
            topHeight: geometry.notch.height
        )
    }

    // MARK: - Hover

    private func pointerEntered() {
        // La ventana puede medir más que la isla durante una animación: solo cuenta entrar en la isla
        guard expansion == .closed, !currentSpaces.isEmpty, pointerIsOverIsland() else { return }
        expansion = .peek
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        growWindow()
        if !reduceMotion {
            withAnimation(Self.hoverAnimation) { model.hovering = true }
        }
        // Vibración del trackpad, con .sensoryFeedback en IslandView como hace Atoll
        model.hoverCount += 1

        openTask?.cancel()
        openTask = Task {
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, expansion == .peek else { return }
            open()
        }
        watchPointer()
    }

    private func open() {
        expansion = .open
        growWindow()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.openAnimation) { model.isExpanded = true }
        Logger.app.info("Isla abierta")
    }

    private func close() {
        openTask?.cancel()
        pointerWatch?.cancel()
        let wasOpen = expansion == .open
        expansion = .closed
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.closeAnimation) {
            model.isExpanded = false
            model.hovering = false
        }
        settleWindow()
        if wasOpen { Logger.app.info("Isla cerrada") }
    }

    // Mientras el puntero está encima se mira dónde está cada 120 ms. Los avisos de salida de macOS fallan en
    // el borde superior de la pantalla, justo donde vive la isla. Con la isla cerrada no corre nada.
    private func watchPointer() {
        pointerWatch?.cancel()
        pointerWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pointerCheckInterval)
                guard !Task.isCancelled, expansion != .closed else { return }
                if !pointerIsOverIsland() {
                    close()
                    return
                }
            }
        }
    }

    // La isla visible, no la ventana (que mide más por la sombra). El píxel superior de la pantalla cuenta como dentro
    private func pointerIsOverIsland() -> Bool {
        guard let geometry else { return false }
        let island = geometry.windowFrame(width: model.islandWidth, height: model.islandHeight)
        return island.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Ventana

    // Marco para el estado actual. Cerrada y en reposo mide justo lo que la isla, para no tapar clics.
    // Con el puntero encima, abierta o durante una animación deja sitio a la sombra y a lo que crece.
    private func targetFrame(roomy: Bool = false) -> NSRect? {
        guard let geometry else { return nil }
        switch expansion {
        case .open:
            let expanded = expandedLayout(for: currentSpaces, geometry: geometry)
            return geometry.windowFrame(
                width: expanded.bodyWidth + 2 * IslandView.openTopRadius + 2 * Self.shadowMargin,
                height: expanded.height + Self.shadowMargin
            )
        case .peek, .closed:
            let width = geometry.centerWidth + 2 * currentLayout.wingWidth + 2 * IslandView.closedTopRadius
            guard roomy || expansion == .peek else {
                return geometry.windowFrame(width: width, height: geometry.notch.height)
            }
            let growth = max(IslandView.pulseGrowth, IslandView.hoverGrowth)
            return geometry.windowFrame(
                width: width + growth + 2 * Self.shadowMargin,
                height: geometry.notch.height + IslandView.hoverGrowth + Self.shadowMargin
            )
        }
    }

    // Antes de animar, la ventana crece a lo que necesiten el estado anterior y el nuevo
    private func growWindow() {
        guard let frame = targetFrame(roomy: true) else { return }
        panel.setFrame(panel.frame.isEmpty ? frame : panel.frame.union(frame), display: true)
    }

    // Al terminar la animación, la ventana vuelve al marco del estado que haya en ese momento
    private func settleWindow() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let frame = targetFrame() else { return }
            panel.setFrame(frame, display: true)
        }
    }

    // Como un aviso de la Dynamic Island: la isla crece un instante y vuelve con un rebote
    private func pulse() {
        withAnimation(.bouncy(duration: 0.25)) { model.pulsing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.bouncy(duration: 0.35)) { model.pulsing = false }
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

// Lienzo de tamaño fijo, centrado y pegado arriba, sobre el que SwiftUI dibuja la isla; la ventana solo lo
// recorta. Al cambiar el marco de la ventana el hosting no cambia de tamaño, SwiftUI no se recoloca y la isla
// no se mueve. Si el hosting se estirase con la ventana, durante un fotograma la isla saltaba a la izquierda.
final class IslandContainerView: NSView {
    var canvasSize = CGSize.zero {
        didSet { placeCanvas() }
    }

    // AppKit lo llama dentro del propio setFrame de la ventana, así que el lienzo se recoloca a la vez
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        placeCanvas()
    }

    private func placeCanvas() {
        for view in subviews {
            view.frame = NSRect(
                x: (bounds.width - canvasSize.width) / 2,
                y: bounds.height - canvasSize.height,
                width: canvasSize.width,
                height: canvasSize.height
            )
        }
    }
}

// Cualquier clic sobre la isla abre el menú de la app
final class IslandHostingView: NSHostingView<IslandView> {
    var menuOnClick: NSMenu?
    var onPointerEntered: (@MainActor () -> Void)?
    private var trackingArea: NSTrackingArea?

    // La isla vive en un panel que nunca se activa: el primer clic tiene que llegar igualmente
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Solo la entrada: la salida la vigila IslandController mirando la posición del puntero.
    // `.activeAlways` porque la app nunca es la activa
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }

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
    /// Con `expanded`, la dibuja abierta un instante (se restaura enseguida, sin llegar a la pantalla).
    func saveSnapshot(expanded: Bool = false) {
        let wasExpanded = model.isExpanded
        model.isExpanded = expanded || wasExpanded
        defer { model.isExpanded = wasExpanded }
        let size = CGSize(width: model.islandWidth + 2 * Self.shadowMargin, height: model.islandHeight + Self.shadowMargin)
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
