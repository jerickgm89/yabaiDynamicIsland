import SwiftUI

// Silueta de la isla. El borde superior ocupa todo el ancho y se curva hacia dentro (`topRadius`) para
// fundirse con el borde de la pantalla; abajo, esquinas redondeadas (`bottomRadius`). Los radios se
// animan al abrir y cerrar. Implementación propia con arcos tangentes.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.height / 2, rect.width / 4))
        let left = rect.minX + top
        let right = rect.maxX - top
        let bottom = max(0, min(bottomRadius, rect.height - top, (right - left) / 2))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: top)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: top)
        path.closeSubpath()
        return path
    }
}

#Preview {
    IslandShape(topRadius: 6, bottomRadius: 14)
        .fill(.black)
        .frame(width: 396, height: 38)
        .padding()
}
