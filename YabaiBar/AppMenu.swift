import AppKit

// Menú de la app, que abre cualquier clic sobre la isla. Se rehace cada vez que se abre, para
// mostrar el error de yabai y el estado de inicio al arrancar.
@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let store: SpacesStore
    private let launchAtLogin: LaunchAtLogin

    init(store: SpacesStore, launchAtLogin: LaunchAtLogin) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        super.init()
        menu.delegate = self
    }

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

    @objc private func refreshFromMenu() {
        store.requestRefresh()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
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
