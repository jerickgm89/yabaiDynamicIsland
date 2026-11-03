import AppKit
import SwiftUI

// Las barras de la música de la isla cerrada, con capas de Core Animation: el sistema de ventanas las anima por su
// cuenta y la app no redibuja nada mientras suenan. Con un efecto de símbolo de SwiftUI, la isla entera se
// redibujaba en cada fotograma y la app gastaba un 20 % de CPU sin parar.
struct MusicBars: NSViewRepresentable {
    var isPlaying: Bool
    /// false con "Reducir movimiento": quietas aunque suene
    var animated: Bool

    func makeNSView(context: Context) -> MusicBarsView { MusicBarsView() }

    func updateNSView(_ view: MusicBarsView, context: Context) {
        view.update(isPlaying: isPlaying, animated: animated)
    }
}

final class MusicBarsView: NSView {
    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2
    /// Cada barra a su ritmo, para que no suban a la vez
    private static let durations: [CFTimeInterval] = [0.43, 0.57, 0.49]
    /// Altura de cada barra quieta, en fracción del alto
    private static let restingScales: [CGFloat] = [0.45, 0.8, 0.6]
    private static let animationKey = "bounce"

    private let bars: [CALayer] = MusicBarsView.durations.map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.cornerRadius = Self.barWidth / 2
            // Crecen desde abajo, como un ecualizador
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    override func layout() {
        super.layout()
        let total = CGFloat(bars.count) * Self.barWidth + CGFloat(bars.count - 1) * Self.spacing
        var x = (bounds.width - total) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            bar.position = CGPoint(x: x + Self.barWidth / 2, y: 0)
            x += Self.barWidth + Self.spacing
        }
        CATransaction.commit()
    }

    func update(isPlaying: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = NSColor.white.withAlphaComponent(isPlaying ? 0.85 : 0.35).cgColor
            bar.transform = CATransform3DMakeScale(1, Self.restingScales[index], 1)
            if isPlaying && animated {
                guard bar.animation(forKey: Self.animationKey) == nil else { continue }
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.25
                bounce.toValue = 1
                bounce.duration = Self.durations[index]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bounce.beginTime = CACurrentMediaTime() - Double(index) * 0.17
                bar.add(bounce, forKey: Self.animationKey)
            } else {
                bar.removeAnimation(forKey: Self.animationKey)
            }
        }
        CATransaction.commit()
    }
}
