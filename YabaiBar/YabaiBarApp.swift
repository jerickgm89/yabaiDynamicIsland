import SwiftUI
import os

@main
struct YabaiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// Raíz de composición: crea una sola instancia de cada pieza, las conecta y recibe los avisos
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SpacesStore?
    private var statusBar: StatusBarController?
    private var island: IslandController?
    private var workspaceObservers: [NSObjectProtocol] = []

    // Lo que macOS avisa por sí solo; ventanas y espacios de yabai llegan por yabaibar://refresh
    private static let refreshNotifications: [Notification.Name] = [
        NSWorkspace.activeSpaceDidChangeNotification,
        NSWorkspace.didActivateApplicationNotification,
        NSWorkspace.didLaunchApplicationNotification,
        NSWorkspace.didTerminateApplicationNotification,
        NSWorkspace.didHideApplicationNotification,
        NSWorkspace.didUnhideApplicationNotification,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let yabai = YabaiClient()
        let store = SpacesStore(yabai: yabai)
        self.store = store
        statusBar = StatusBarController(store: store, renderer: BarRenderer(), launchAtLogin: LaunchAtLogin())
        island = IslandController()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = Self.refreshNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Logger.app.info("Aviso: \(name.rawValue, privacy: .public)")
                    store.requestRefresh()
                }
            }
        }
        store.requestRefresh()
    }

    // yabaibar://refresh desde las señales de yabai y skhd; yabaibar://snapshot solo en DEBUG
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "yabaibar" {
            switch url.host() {
            case "refresh":
                Logger.app.info("Aviso: yabaibar://refresh")
                store?.requestRefresh()
            #if DEBUG
            case "snapshot":
                statusBar?.saveSnapshot()
            #endif
            default:
                Logger.app.info("URL sin acción: \(url.absoluteString, privacy: .public)")
            }
        }
    }
}
