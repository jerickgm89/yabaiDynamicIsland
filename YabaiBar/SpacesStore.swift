import Foundation
import Observation
import os

@MainActor
@Observable
final class SpacesStore {
    private(set) var spaces: [SpaceSummary] = []
    private(set) var lastError: YabaiError?

    @ObservationIgnored private let yabai: any YabaiQuerying
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(yabai: any YabaiQuerying, debounce: Duration = .milliseconds(100)) {
        self.yabai = yabai
        self.debounce = debounce
    }

    /// Agrupa avisos seguidos: consulta a yabai solo cuando pasa `debounce` sin otro aviso.
    func requestRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            // Desde aquí no se cancela: si llega otro aviso, el contador de generación descarta este resultado
            pendingRefresh = nil
            await refresh()
        }
    }

    func refresh() async {
        generation += 1
        let current = generation
        let client = yabai
        do {
            async let spacesQuery = client.spaces()
            async let windowsQuery = client.windows()
            let (allSpaces, allWindows) = try await (spacesQuery, windowsQuery)
            guard current == generation else { return }
            update(spaces: SpaceGrouper.group(spaces: allSpaces, windows: allWindows), error: nil)
            Logger.app.info("Refresco \(current): \(self.spaces.count) espacios")
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            let yabaiError = error as? YabaiError ?? .commandFailed(command: "yabai", stderr: String(describing: error))
            update(spaces: [], error: yabaiError)
            Logger.app.error("yabai no respondió: \(String(describing: yabaiError), privacy: .public)")
        }
    }

    // Solo asigna si cambia, para no disparar redibujos sin motivo
    private func update(spaces newSpaces: [SpaceSummary], error: YabaiError?) {
        if spaces != newSpaces { spaces = newSpaces }
        if lastError != error { lastError = error }
    }
}
