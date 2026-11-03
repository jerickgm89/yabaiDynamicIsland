import Foundation

// Lógica pura del gesto de 3 o 4 dedos hacia abajo en el trackpad. Recibe los dedos apoyados en cada fotograma,
// con su posición normalizada (de 0 a 1, con la y hacia arriba), y avisa una sola vez por gesto.
// Hacia arriba y a los lados no cuenta: en esta máquina son Mission Control y el cambio de escritorio.
struct FingerSwipeDetector {
    struct Finger: Equatable {
        var x: Float
        var y: Float
    }

    static let fingerCounts = 3...4
    /// Lo que tienen que bajar los dedos, en fracción del alto del trackpad (en uno de 16" es 1 cm)
    static let threshold: Float = 0.1

    private var last: (count: Int, x: Float, y: Float)?
    private var travelX: Float = 0
    /// Positivo hacia abajo
    private var travelY: Float = 0
    private var fired = false

    /// true la primera vez que el gesto en curso baja lo bastante; el gesto termina al quedar menos de 3 dedos
    mutating func track(_ fingers: [Finger]) -> Bool {
        guard Self.fingerCounts.contains(fingers.count) else {
            self = FingerSwipeDetector()
            return false
        }
        let count = Float(fingers.count)
        let x = fingers.map(\.x).reduce(0, +) / count
        let y = fingers.map(\.y).reduce(0, +) / count
        // Si un dedo llega o se levanta a mitad del gesto, el centro salta: ese fotograma no cuenta
        if let last, last.count == fingers.count {
            travelX += x - last.x
            travelY += last.y - y
        }
        last = (fingers.count, x, y)
        guard !fired, travelY >= Self.threshold, travelY > abs(travelX) else { return false }
        fired = true
        return true
    }
}
