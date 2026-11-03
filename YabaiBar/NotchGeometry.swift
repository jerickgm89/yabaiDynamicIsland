import Foundation

// Geometría pura de la isla: dónde está el notch y qué marco necesita la ventana.
// Recibe los datos de NSScreen ya extraídos para poder testearla con las medidas reales de la pantalla.
struct NotchGeometry: Equatable {
    /// Lo que la isla rebasa el notch por cada lado, para que no se vea la costura entre los dos negros
    static let seamOverlap: CGFloat = 2
    /// Medidas que se suponen en una pantalla sin notch (la píldora de la fase 12)
    static let fallbackNotchWidth: CGFloat = 180
    static let fallbackHeight: CGFloat = 32

    /// En coordenadas de pantalla de AppKit (origen abajo a la izquierda)
    let notch: CGRect
    let hasNotch: Bool

    init(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?, topInset: CGFloat) {
        if let left = topLeftArea, let right = topRightArea, topInset > 0 {
            notch = CGRect(x: left.maxX, y: screenFrame.maxY - topInset, width: right.minX - left.maxX, height: topInset)
            hasNotch = true
        } else {
            notch = CGRect(
                x: screenFrame.midX - Self.fallbackNotchWidth / 2, y: screenFrame.maxY - Self.fallbackHeight,
                width: Self.fallbackNotchWidth, height: Self.fallbackHeight
            )
            hasNotch = false
        }
    }

    /// Ancho del cuerpo central de la isla: el notch más la costura de cada lado
    var centerWidth: CGFloat { notch.width + 2 * Self.seamOverlap }

    /// Marco de la ventana, centrado en el notch y pegado al borde superior. Las esquinas superiores
    /// cóncavas de la isla ocupan `topRadius` por cada lado además de las alas.
    func windowFrame(wingWidth: CGFloat, topRadius: CGFloat, height: CGFloat? = nil) -> CGRect {
        windowFrame(width: centerWidth + 2 * wingWidth + 2 * topRadius, height: height ?? notch.height)
    }

    /// Marco de una ventana de ese tamaño, centrado en el notch y pegado al borde superior
    func windowFrame(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)
    }
}
