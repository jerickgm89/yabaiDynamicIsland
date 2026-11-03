import AppKit
import Observation
import SwiftUI
import os

// Coloca la isla sobre el notch, la anima cuando cambian los espacios y, abierta, lleva al escritorio de la
// tarjeta que se pulse; cualquier otro clic abre el menú.
// En reposo la ventana mide justo lo que la isla, para no tapar los clics de la barra de menús alrededor.
@MainActor
final class IslandController {
    // Valores de Atoll para el contenido, el hover, la apertura y el cierre
    static let changeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let hoverAnimation = Animation.bouncy.speed(1.2)
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 1.0)
    static let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let reducedAnimation = Animation.easeInOut(duration: 0.2)
    // Cambio de escritorio: las alas se recogen y vuelven a salir con un rebote suave, sin prisa
    static let tuckAnimation = Animation.smooth(duration: 0.3)
    static let untuckAnimation = Animation.spring(response: 0.6, dampingFraction: 0.8)
    /// Tiempo mínimo recogidas, para que se vea el gesto aunque yabai responda enseguida
    static let minimumTuck: Duration = .milliseconds(300)
    /// Si no llega contenido nuevo (gesto cancelado o mismo escritorio), las alas vuelven solas
    static let tuckTimeout: Duration = .milliseconds(900)
    /// Fundido de la ventana entera al empezar un cambio de escritorio
    static let windowFadeDuration: TimeInterval = 0.15
    /// Lo que se espera, tras un cambio, para devolver la ventana a su tamaño justo
    static let settleDelay: Duration = .milliseconds(1400)
    /// Lo que tiene que estar el puntero encima para que la isla se abra
    static let openDelay: Duration = .milliseconds(300)
    static let pointerCheckInterval: Duration = .milliseconds(120)
    /// Las tarjetas se iluminan bajo el puntero y se hunden al pulsarlas
    static let cardAnimation = Animation.smooth(duration: 0.2)
    /// Al elegir un escritorio la isla se recoge entera en el notch; el atajo se pulsa cuando ya casi lo ha hecho,
    /// para que el encogimiento se vea antes de que macOS empiece a deslizar
    static let switchDelay: Duration = .milliseconds(200)
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
    private let focuser: ShortcutFocuser
    private var geometry: NotchGeometry?
    private var screenWidth: CGFloat = 0
    // Copias de lo dibujado. No se leen del modelo dentro de render(): withObservationTracking
    // registraría el modelo y cada cambio volvería a llamar a render() sin fin
    private var currentLayout = IslandLayout(spaces: [])
    private var currentSpaces: [SpaceSummary] = []
    private var expansion = Expansion.closed
    private var settleTask: Task<Void, Never>?
    private var tuckedAt: ContinuousClock.Instant?
    private var untuckTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var pointerWatch: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    init(store: SpacesStore, icons: AppIcons, menu: AppMenu, focuser: ShortcutFocuser) {
        self.store = store
        self.icons = icons
        self.focuser = focuser
        hosting = IslandHostingView(rootView: IslandView(model: model))
        // Que la vista no cambie el tamaño de la ventana: el marco lo decide NotchGeometry
        hosting.sizingOptions = []
        hosting.menuOnClick = menu.menu
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        hosting.onPointerMoved = { [weak self] in self?.updateHoveredCard() }
        hosting.onPress = { [weak self] in self?.pressCard() ?? false }
        hosting.onRelease = { [weak self] in self?.releaseCard() }
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

        // La ventana deja de verse en cuanto empieza un cambio de escritorio (al iniciar el gesto del trackpad
        // o al pulsar ⌥N), entre 0,1 y casi 1 s antes de activeSpaceDidChange: ahí se recogen las alas
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
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
        currentLayout = layout
        currentSpaces = spaces
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let description = Self.title(for: spaces, failed: failed)
        let update = {
            self.model.centerWidth = geometry.centerWidth
            self.model.height = geometry.notch.height
            self.model.layout = layout
            self.model.expanded = self.expandedLayout(for: spaces, geometry: geometry)
            self.model.icons = self.icons.icons(for: spaces)
            self.model.fallbackText = spaces.isEmpty ? description : nil
            self.model.reduceMotion = reduceMotion
        }

        // La ventana crece antes de animar y se ajusta al terminar, para que la isla nunca se recorte
        growWindow()
        if let tuckedAt {
            // Alas recogidas por un cambio de escritorio: el contenido cambia sin animar, porque no se ve,
            // y después vuelven a salir con el contenido nuevo
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
            scheduleUntuck(after: max(.zero, Self.minimumTuck - (ContinuousClock.now - tuckedAt)))
        } else {
            withAnimation(reduceMotion ? Self.reducedAnimation : Self.changeAnimation, update)
        }
        settleWindow()
        Logger.app.info("Isla: \(description, privacy: .public) (alas de \(Int(layout.wingWidth)) pt)")
    }

    // MARK: - Cambio de escritorio

    /// Aviso de macOS de que el cambio de escritorio terminó. Normalmente las alas ya se recogieron al
    /// empezar (ver occlusionChanged); si no, se recogen ahora. Vuelven a salir cuando llega el contenido nuevo.
    func spaceDidChange() {
        tuckWings()
        if tuckedAt != nil { scheduleUntuck(after: Self.tuckTimeout) }
    }

    private func occlusionChanged() {
        if panel.occlusionState.contains(.visible) {
            // De vuelta en pantalla: si no llega contenido nuevo (gesto cancelado), las alas vuelven solas
            if tuckedAt != nil { scheduleUntuck(after: Self.tuckTimeout) }
        } else {
            tuckWings()
            // Oculta, SwiftUI deja de dibujarla: al volver, macOS enseñaría un instante el último fotograma
            // (la isla entera) y luego saltaría a recogida, y durante el gesto se verían fotogramas a medias.
            // La ventana se apaga con un fundido del propio sistema de ventanas y se enciende ya recogida.
            if tuckedAt != nil { fadeWindow(to: 0) }
        }
    }

    private func fadeWindow(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.windowFadeDuration
            panel.animator().alphaValue = alpha
        }
    }

    private func tuckWings() {
        guard expansion == .closed, !currentSpaces.isEmpty, tuckedAt == nil else { return }
        tuckedAt = .now
        untuckTask?.cancel()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.tuckAnimation) { model.wingsTucked = true }
    }

    private func scheduleUntuck(after delay: Duration) {
        untuckTask?.cancel()
        untuckTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            untuckWings()
        }
    }

    private func untuckWings() {
        tuckedAt = nil
        // Recogida, la isla mide lo que el notch y es negra como él: encenderla de golpe no se nota
        panel.alphaValue = 1
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.untuckAnimation) { model.wingsTucked = false }
        settleWindow()
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
        // La ventana puede medir más que la isla durante una animación: solo cuenta entrar en la isla.
        // Mientras cambia el escritorio (alas recogidas) no se abre
        guard expansion == .closed, tuckedAt == nil, !currentSpaces.isEmpty, pointerIsOverIsland() else { return }
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
        // Los atajos se leen al abrir: así se ven los cambios hechos en Ajustes sin reiniciar la app
        model.shortcutLabels = focuser.labels(for: currentSpaces.map(\.index))
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
            model.hoveredSpace = nil
            model.pressedSpace = nil
        }
        settleWindow()
        if wasOpen { Logger.app.info("Isla cerrada") }
    }

    // Mientras el puntero está encima se mira dónde está cada 120 ms. Los avisos de salida de macOS fallan en
    // el borde superior de la pantalla, justo donde vive la isla. Con la isla cerrada no corre nada.
    // También repasa la tarjeta bajo el puntero, por si se perdió algún aviso de movimiento.
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
                updateHoveredCard()
            }
        }
    }

    // La isla visible, no la ventana (que mide más por la sombra). El píxel superior de la pantalla cuenta como dentro
    private func pointerIsOverIsland() -> Bool {
        guard let geometry else { return false }
        let island = geometry.windowFrame(width: model.islandWidth, height: model.islandHeight)
        return island.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Tarjetas

    // La tarjeta bajo el puntero con la isla abierta. Sale de la geometría de la isla en pantalla y no de onHover
    // de SwiftUI, que no es fiable en un panel que nunca se activa.
    private func spaceUnderPointer() -> SpaceSummary? {
        guard expansion == .open, let geometry else { return nil }
        let island = geometry.windowFrame(width: model.islandWidth, height: model.islandHeight)
        let pointer = NSEvent.mouseLocation
        // Coordenadas de la isla con el origen arriba a la izquierda, como las dibuja SwiftUI
        let point = CGPoint(x: pointer.x - island.minX, y: island.maxY - pointer.y)
        let expanded = model.expanded
        guard let index = expanded.cardIndex(at: point, islandWidth: island.width, topHeight: geometry.notch.height) else {
            return nil
        }
        return expanded.spaces[index]
    }

    // Solo se iluminan las tarjetas a las que se puede ir
    private func updateHoveredCard() {
        let hovered = spaceUnderPointer().flatMap { model.canSwitch(to: $0) ? $0.index : nil }
        guard hovered != model.hoveredSpace else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) { model.hoveredSpace = hovered }
    }

    /// Pulsar una tarjeta la hunde. Devuelve false si el clic no cae en ninguna, y entonces se abre el menú
    private func pressCard() -> Bool {
        guard let space = spaceUnderPointer() else { return false }
        guard model.canSwitch(to: space) else { return true }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) {
            model.hoveredSpace = space.index
            model.pressedSpace = space.index
        }
        return true
    }

    // Como un botón: el cambio llega al soltar, y solo si el puntero sigue en la misma tarjeta
    private func releaseCard() {
        guard let pressed = model.pressedSpace else { return }
        let space = spaceUnderPointer()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.cardAnimation) { model.pressedSpace = nil }
        guard let space, space.index == pressed else { return }
        switchTo(space)
    }

    private func switchTo(_ space: SpaceSummary) {
        // Ya estás ahí: solo se cierra la isla
        guard !space.isFocused else { return close() }
        switch focuser.readiness(for: space.index) {
        case .noShortcut:
            Logger.app.info("El escritorio \(space.index) no tiene atajo en Ajustes › Teclado › Atajos")
        case .needsPermission:
            Logger.app.info("Falta el permiso de Accesibilidad para ir al escritorio \(space.index)")
            close()
            focuser.requestPermission()
        case .ready:
            Logger.app.info("Clic: ir al escritorio \(space.index)")
            collapseIntoNotch()
            Task {
                try? await Task.sleep(for: Self.switchDelay)
                if !focuser.focus(space: space.index) {
                    Logger.app.error("No se pudo pulsar el atajo del escritorio \(space.index)")
                }
            }
            // Si el escritorio no llega a cambiar, las alas vuelven solas
            scheduleUntuck(after: Self.switchDelay + Self.tuckTimeout)
        }
    }

    // Cierra la isla y recoge las alas en un solo movimiento: se encoge hasta el notch y, al llegar al
    // escritorio nuevo, las alas salen con su contenido como en cualquier otro cambio (ver occlusionChanged)
    private func collapseIntoNotch() {
        openTask?.cancel()
        pointerWatch?.cancel()
        untuckTask?.cancel()
        expansion = .closed
        tuckedAt = .now
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? Self.reducedAnimation : Self.closeAnimation) {
            model.isExpanded = false
            model.hovering = false
            model.hoveredSpace = nil
            model.wingsTucked = true
        }
        settleWindow()
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
            return geometry.windowFrame(
                width: width + IslandView.hoverGrowth + 2 * Self.shadowMargin,
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

// El clic en una tarjeta de la isla abierta lo gestiona IslandController; cualquier otro abre el menú de la app
final class IslandHostingView: NSHostingView<IslandView> {
    var menuOnClick: NSMenu?
    var onPointerEntered: (@MainActor () -> Void)?
    var onPointerMoved: (@MainActor () -> Void)?
    /// Devuelve true si el clic cae en una tarjeta; si no, se abre el menú
    var onPress: (@MainActor () -> Bool)?
    var onRelease: (@MainActor () -> Void)?
    private var trackingArea: NSTrackingArea?

    // La isla vive en un panel que nunca se activa: el primer clic tiene que llegar igualmente
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // La entrada y el movimiento (para la tarjeta bajo el puntero): la salida la vigila IslandController
    // mirando la posición del puntero. `.activeAlways` porque la app nunca es la activa
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved?()
    }

    override func mouseDown(with event: NSEvent) {
        if onPress?() == true { return }
        showMenu(for: event)
    }

    // AppKit manda el mouseUp a la vista que recibió el mouseDown, aunque el puntero ya no esté encima
    override func mouseUp(with event: NSEvent) { onRelease?() }

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
                // Como un cambio real: primero el aviso de macOS (recoge las alas) y luego el contenido
                spaceDidChange()
                apply(spaces: base.map { SpaceSummary(index: $0.index, isFocused: $0.index == focused, apps: $0.apps) }, failed: false)
                try? await Task.sleep(for: interval)
            }
            render()
            Logger.app.info("Prueba de estrés terminada: \(rounds) cambios")
        }
    }

    /// Guarda la isla como PNG ampliado y sobre un fondo gris, para revisarla sin mirar la pantalla.
    /// Con `expanded`, la dibuja abierta un instante (se restaura enseguida, sin llegar a la pantalla);
    /// con `hoveringCard`, además con el puntero sobre la primera tarjeta inactiva a la que se puede ir.
    func saveSnapshot(expanded: Bool = false, hoveringCard: Bool = false) {
        let wasExpanded = model.isExpanded
        let wasHovered = model.hoveredSpace
        model.isExpanded = expanded || hoveringCard || wasExpanded
        if model.isExpanded { model.shortcutLabels = focuser.labels(for: currentSpaces.map(\.index)) }
        if hoveringCard {
            model.hoveredSpace = currentSpaces.first { !$0.isFocused && model.canSwitch(to: $0) }?.index
        }
        defer {
            model.isExpanded = wasExpanded
            model.hoveredSpace = wasHovered
        }
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
