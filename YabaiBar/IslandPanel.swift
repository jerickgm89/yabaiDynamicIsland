import AppKit

// Ventana de la isla: transparente, sin sombra propia, por encima de la barra de menús y presente en
// todos los espacios (también junto a apps a pantalla completa). Nunca se activa ni roba el foco.
// Es `.transient`: Mission Control la oculta, como a la barra de menús. Con `.stationary` se quedaba encima de la
// barra de escritorios de Mission Control y, al pasar el puntero, se abría y se cerraba varias veces.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // El aviso de los atajos de escritorio (DesktopShortcutAssistant) es modal: sin esto, mientras está abierto
        // la isla no recibiría clics
        worksWhenModal = true
    }

    // AppKit baja las ventanas que tocan la barra de menús; la isla tiene que quedarse pegada arriba
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
