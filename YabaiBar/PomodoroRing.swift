import AppKit
import SwiftUI

// El anillo del Pomodoro en la isla cerrada, con capas de Core Animation: el arco crece desde las doce, en el
// sentido del reloj, con una sola animación que dura lo que queda de la fase. La anima el sistema de ventanas y la
// app no redibuja nada mientras corre (ver MusicBars).
struct PomodoroRing: NSViewRepresentable {
    /// Lo que va de la fase, de 0 a 1
    var progress: Double
    /// Lo que queda si está en marcha; nil en pausa o lista, y entonces el arco se queda quieto
    var remaining: TimeInterval?
    var color: NSColor
    /// Cambia al empezar, pausar o reanudar una fase: solo entonces se vuelve a crear la animación
    var key: String

    func makeNSView(context: Context) -> PomodoroRingView { PomodoroRingView() }

    func updateNSView(_ view: PomodoroRingView, context: Context) {
        view.update(progress: progress, remaining: remaining, color: color, key: key)
    }
}

final class PomodoroRingView: NSView {
    private static let lineWidth: CGFloat = 2.2
    private static let animationKey = "progress"

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var currentKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    // Desde las doce y en el sentido del reloj. Las capas tienen la y hacia arriba
    override func layout() {
        super.layout()
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    func update(progress: Double, remaining: TimeInterval?, color: NSColor, key: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = color.cgColor
        defer { CATransaction.commit() }
        // SwiftUI vuelve a llamar por cualquier cambio de la isla: la animación solo se rehace si cambió la fase
        guard key != currentKey else { return }
        currentKey = key
        arc.removeAnimation(forKey: Self.animationKey)
        arc.strokeEnd = progress
        guard let remaining, remaining > 0 else { return }
        let grow = CABasicAnimation(keyPath: "strokeEnd")
        grow.fromValue = progress
        grow.toValue = 1
        grow.duration = remaining
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        grow.fillMode = .forwards
        grow.isRemovedOnCompletion = false
        arc.add(grow, forKey: Self.animationKey)
    }
}
