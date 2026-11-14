import Foundation

// La espera entre medidas de un módulo que consulta cada cierto tiempo (Puertos, Docker): una sola tarea, con tolerancia
// (sin ella, macOS retrasa las esperas largas, ajuste 21) y con una generación que sube en cada arranque y parada. Una
// medida que se pidió antes de que cambiara ya no se publica: cancelar la tarea no basta, porque la consulta tarda y la
// pestaña pudo cerrarse y abrirse mientras tanto (como en SpacesStore, ajuste 3).
@MainActor
final class Poller {
    private var task: Task<Void, Never>?
    private(set) var generation = 0

    var isRunning: Bool { task != nil }

    /// Mide ya y después cada `interval`. `work` recibe la generación con la que empezó
    func start(interval: Duration, work: @escaping @MainActor (_ generation: Int) async -> Void) {
        guard task == nil else { return }
        generation += 1
        let generation = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                await work(generation)
                try? await Task.sleep(for: interval, tolerance: .milliseconds(300))
                guard !Task.isCancelled, self != nil else { return }
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        generation += 1
        task?.cancel()
        task = nil
    }

    /// La medida de esa generación todavía vale: no se paró ni se volvió a arrancar desde entonces
    func isCurrent(_ generation: Int) -> Bool {
        task != nil && generation == self.generation
    }
}
