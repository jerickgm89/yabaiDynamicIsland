import SwiftUI
import notify
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
    private var menu: AppMenu?
    private var island: IslandController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshToken: Int32 = NOTIFY_TOKEN_INVALID

    // Las señales de yabai y los atajos de skhd avisan con `notifyutil -p com.jerickdev.yabaibar.refresh`.
    // La notificación llega a la instancia que está corriendo; una URL pasaría por LaunchServices,
    // que con dos copias de la app (la de build/ y la de /Applications) abría la otra
    static let refreshNotificationName = "com.jerickdev.yabaibar.refresh"

    // Lo que macOS avisa por sí solo; ventanas y espacios de yabai llegan por la notificación de refresco
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
        let menu = AppMenu(store: store, launchAtLogin: LaunchAtLogin())
        self.menu = menu
        island = IslandController(store: store, icons: AppIcons(), menu: menu)

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = Self.refreshNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Logger.app.info("Aviso: \(name.rawValue, privacy: .public)")
                    store.requestRefresh()
                }
            }
        }
        notify_register_dispatch(Self.refreshNotificationName, &refreshToken, .main) { _ in
            MainActor.assumeIsolated {
                Logger.app.info("Aviso: notificación de refresco")
                store.requestRefresh()
            }
        }
        store.requestRefresh()
    }

    // yabaibar://refresh sigue funcionando para usarlo a mano; yabaibar://snapshot solo en DEBUG
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "yabaibar" {
            switch url.host() {
            case "refresh":
                Logger.app.info("Aviso: yabaibar://refresh")
                store?.requestRefresh()
            #if DEBUG
            case "snapshot":
                island?.saveSnapshot()
            #endif
            default:
                Logger.app.info("URL sin acción: \(url.absoluteString, privacy: .public)")
            }
        }
    }
}
