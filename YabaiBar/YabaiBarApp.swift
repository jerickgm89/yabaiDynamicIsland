import SwiftUI
import os

@main
struct YabaiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let yabai = YabaiClient()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "YB"
        statusItem = item

        // Fase 2: comprobar el cliente en el log; en la fase 3 lo sustituye SpacesStore
        Task { await logSpaces() }
    }

    private func logSpaces() async {
        let client = yabai
        do {
            async let spaces = client.spaces()
            async let windows = client.windows()
            let (allSpaces, allWindows) = try await (spaces, windows)
            for space in allSpaces.sorted(by: { $0.index < $1.index }) {
                let apps = allWindows.filter { $0.space == space.index }.map(\.app).joined(separator: ", ")
                let marker = space.hasFocus ? " (activo)" : ""
                Logger.app.info("Espacio \(space.index)\(marker, privacy: .public): \(apps, privacy: .public)")
            }
        } catch {
            Logger.app.error("yabai no respondió: \(String(describing: error), privacy: .public)")
        }
    }
}
