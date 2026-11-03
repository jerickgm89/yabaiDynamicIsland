import Foundation

// Lógica pura del gesto de dos dedos de lado sobre la franja de música: dedos a la izquierda, siguiente canción;
// a la derecha, anterior, como al pasar páginas. Cuenta el movimiento real de los dedos, con o sin desplazamiento
// natural, y avisa una sola vez por gesto. La inercia que macOS sigue mandando al levantar los dedos no cuenta.
struct SideSwipeTracker {
    enum Direction: Equatable { case left, right }

    /// Lo que interesa de un evento de scroll de AppKit
    struct Sample {
        enum Phase { case began, changed, ended, none }

        /// `none`: la rueda de un ratón, o la inercia, sin principio ni fin de gesto
        var phase: Phase
        /// scrollingDeltaX de AppKit
        var deltaX: CGFloat
        var deltaY: CGFloat = 0
        /// Desplazamiento natural: el contenido sigue a los dedos y deltaX tiene el signo de su movimiento
        var isDirectionInverted = true
        var isMomentum = false

        /// Movimiento horizontal de los dedos, positivo hacia la derecha
        var fingerDeltaX: CGFloat { isDirectionInverted ? deltaX : -deltaX }
    }

    /// Recorrido horizontal de los dedos, en puntos, para que cuente como gesto
    static let threshold: CGFloat = 40

    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var fired = false

    /// La dirección, la primera vez que el gesto en curso pasa el umbral; el resto de muestras, nil
    mutating func track(_ sample: Sample) -> Direction? {
        guard !sample.isMomentum else { return nil }
        switch sample.phase {
        case .began:
            self = SideSwipeTracker()
        case .changed:
            break
        case .ended:
            self = SideSwipeTracker()
            return nil
        case .none:
            return nil
        }
        travelX += sample.fingerDeltaX
        travelY += sample.deltaY
        // Solo si el gesto es sobre todo horizontal
        guard !fired, abs(travelX) >= Self.threshold, abs(travelX) > abs(travelY) else { return nil }
        fired = true
        return travelX > 0 ? .right : .left
    }
}
