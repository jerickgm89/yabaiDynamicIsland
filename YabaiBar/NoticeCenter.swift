import Foundation

// Recibe los avisos que otros procesos de YabaiBar mandan por `DistributedNotificationCenter` (hoy, el ayudante `yb` con los
// eventos de los hooks de Claude Code). Esa notificación es de todo el sistema: cualquier proceso puede mandar una con
// nuestro nombre. Por eso solo se aceptan los avisos bien formados (`AvisoMessage`), como mucho `limit` cada `window`
// segundos, y lo que dicen solo cambia lo que enseña la isla.
@MainActor
final class NoticeCenter {
    /// Los hooks de Claude Code mandan muchos avisos (uno por herramienta): 100 cada 5 s
    static let limit = 100
    /// Los de la terminal son pocos: 20 cada 5 s. Cada tipo tiene su cupo, para que un bucle de `yb aviso` no gaste el de los hooks de
    /// Claude (y deje una pregunta colgada) ni al revés
    static let terminalLimit = 20
    static let window: TimeInterval = 5

    private var observer: NSObjectProtocol?
    private var limiters: [AvisoMessage.Kind: EventRateLimiter] = [:]
    private let now: @Sendable () -> Date
    /// El nombre de la notificación. Los tests usan uno propio: con el real, escucharían los avisos de las sesiones de verdad
    private let name: Notification.Name

    init(
        name: Notification.Name = Notification.Name(AvisoMessage.notificationName),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.name = name
        self.now = now
    }

    func start(_ handler: @escaping @MainActor @Sendable (AvisoMessage) -> Void) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] notification in
            guard let message = AvisoMessage(userInfo: notification.userInfo) else { return }
            MainActor.assumeIsolated {
                guard let self, self.allow(message.kind) else { return }
                handler(message)
            }
        }
    }

    private func allow(_ kind: AvisoMessage.Kind) -> Bool {
        var limiter = limiters[kind] ?? EventRateLimiter(limit: kind == .terminal ? Self.terminalLimit : Self.limit, window: Self.window)
        let allowed = limiter.allow(at: now())
        limiters[kind] = limiter
        return allowed
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}
