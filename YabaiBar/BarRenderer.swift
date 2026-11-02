import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Convierte los espacios en la imagen de la barra: resuelve los íconos y dibuja BarView con ImageRenderer
@MainActor
final class BarRenderer {
    private static let fallbackIcon = NSWorkspace.shared.icon(for: .application)
    private var iconCache: [Int32: NSImage] = [:]

    func render(_ spaces: [SpaceSummary], isDark: Bool, scale: CGFloat) -> (image: NSImage, layout: BarLayout) {
        let layout = BarLayout(spaces: spaces)
        let view = BarView(layout: layout, icons: icons(for: spaces), foreground: isDark ? .white : .black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: layout.width, height: BarLayout.height))
        // Los íconos son de color: una imagen template los pintaría de un solo tono
        image.isTemplate = false
        return (image, layout)
    }

    // Reutiliza los íconos ya resueltos y olvida los de procesos que ya no aparecen
    private func icons(for spaces: [SpaceSummary]) -> [Int32: NSImage] {
        var icons: [Int32: NSImage] = [:]
        for app in spaces.flatMap(\.apps) {
            icons[app.pid] = iconCache[app.pid]
                ?? NSRunningApplication(processIdentifier: app.pid)?.icon
                ?? Self.fallbackIcon
        }
        iconCache = icons
        return icons
    }
}
