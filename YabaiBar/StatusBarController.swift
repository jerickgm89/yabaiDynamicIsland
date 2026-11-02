import AppKit
import Observation
import os

@MainActor
final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: SpacesStore

    init(store: SpacesStore) {
        self.store = store
        observeStore()
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
        let title = Self.title(for: store.spaces, failed: store.lastError != nil)
        statusItem.button?.title = title
        Logger.app.info("Barra: \(title, privacy: .public)")
    }

    // Fase 3: texto "1 2 [3] 4"; en la fase 4 lo sustituye la imagen de BarView
    nonisolated static func title(for spaces: [SpaceSummary], failed: Bool) -> String {
        if failed { return "YB ⚠︎" }
        if spaces.isEmpty { return "YB" }
        return spaces.map { $0.isFocused ? "[\($0.index)]" : "\($0.index)" }.joined(separator: " ")
    }
}
