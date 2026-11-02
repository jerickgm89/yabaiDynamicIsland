import SwiftUI

// Fase 8: solo la silueta negra que alarga el notch; el contenido llega en la fase 9
struct IslandView: View {
    // Radios de la isla cerrada, los mismos que usa Atoll
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14

    var body: some View {
        IslandShape(topRadius: Self.closedTopRadius, bottomRadius: Self.closedBottomRadius)
            .fill(.black)
    }
}
