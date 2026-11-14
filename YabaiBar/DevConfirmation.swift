import AppKit

// La pregunta antes de algo que quita o para algo (cerrar un proceso, parar un contenedor): un aviso nativo con
// «Cancelar» como botón por defecto, para que un Intro sin querer no confirme.
@MainActor
enum DevConfirmation {
    /// true si el usuario confirmó
    static func confirm(title: String, message: String, action: String, destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: action).hasDestructiveAction = destructive
        // La app no sale en el Dock ni en ⌘⇥: el aviso va por encima de las ventanas normales, para que no se pierda
        // detrás de otra app, y la app se activa para que reciba el teclado (como el de los atajos de escritorio)
        let wasActive = NSApp.isActive
        alert.window.level = .floating
        NSApp.activate()
        let response = alert.runModal()
        if !wasActive { NSApp.deactivate() }
        return response == .alertSecondButtonReturn
    }
}
