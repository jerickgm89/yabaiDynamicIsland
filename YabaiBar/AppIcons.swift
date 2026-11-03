import AppKit
import UniformTypeIdentifiers

// Íconos de las apps por pid, con caché. En cada llamada se olvidan los de procesos que ya no aparecen.
@MainActor
final class AppIcons {
    private static let fallbackIcon = NSWorkspace.shared.icon(for: .application)
    private var cache: [Int32: NSImage] = [:]

    func icons(for spaces: [SpaceSummary]) -> [Int32: NSImage] {
        var icons: [Int32: NSImage] = [:]
        for app in spaces.flatMap(\.apps) {
            icons[app.pid] = cache[app.pid]
                ?? NSRunningApplication(processIdentifier: app.pid)?.icon
                ?? Self.fallbackIcon
        }
        cache = icons
        return icons
    }
}
