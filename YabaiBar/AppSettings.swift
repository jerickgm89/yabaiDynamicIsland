import Foundation
import Observation
import SwiftUI

// Ajustes del usuario, guardados en UserDefaults: la velocidad de las alas al cambiar de escritorio, cómo se abre
// la isla (con el puntero, con el atajo, si se oculta sola) y qué música muestra.
@MainActor
@Observable
final class AppSettings {
    static let defaultAutoHideDelay = 3
    static let autoHideDelays = 1...10

    var switchSpeed: SwitchSpeed {
        didSet { defaults.set(switchSpeed.rawValue, forKey: Key.switchSpeed) }
    }

    /// nil: la isla no tiene atajo y solo se abre a petición con el gesto. Se guarda vacío, para distinguirlo de
    /// no haberlo cambiado nunca
    var toggleShortcut: HotKeyShortcut? {
        didSet {
            let data = toggleShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            defaults.set(data, forKey: Key.toggleShortcut)
        }
    }

    /// Abierta con el atajo o con el gesto, se oculta sola si el puntero no llega a la isla
    var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: Key.autoHide) }
    }

    /// En segundos
    var autoHideDelay: Int {
        didSet { defaults.set(autoHideDelay, forKey: Key.autoHideDelay) }
    }

    /// Si no, la isla solo se abre con el atajo o el gesto
    var openOnHover: Bool {
        didSet { defaults.set(openOnHover, forKey: Key.openOnHover) }
    }

    /// La franja "Ahora suena" de la isla abierta. Apagada, el adaptador no corre
    var showNowPlaying: Bool {
        didSet { defaults.set(showNowPlaying, forKey: Key.showNowPlaying) }
    }

    var nowPlayingSource: NowPlayingSource {
        didSet { defaults.set(nowPlayingSource.rawValue, forKey: Key.nowPlayingSource) }
    }

    /// Mientras se graba un atajo nuevo no se escucha el actual: Carbon se lo quedaría antes que la ventana
    var isRecordingShortcut = false
    /// Por qué no se pudo registrar el atajo, para mostrarlo en los ajustes
    var shortcutError: String?

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let switchSpeed = "switchSpeed"
        static let toggleShortcut = "toggleShortcut"
        static let autoHide = "autoHide"
        static let autoHideDelay = "autoHideDelay"
        static let openOnHover = "openOnHover"
        static let showNowPlaying = "showNowPlaying"
        static let nowPlayingSource = "nowPlayingSource"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        switchSpeed = defaults.string(forKey: Key.switchSpeed).flatMap(SwitchSpeed.init(rawValue:)) ?? .normal
        // Sin valor guardado (o ilegible), ⌥I; guardado vacío, sin atajo
        switch defaults.data(forKey: Key.toggleShortcut) {
        case let data? where data.isEmpty:
            toggleShortcut = nil
        case let data?:
            toggleShortcut = (try? JSONDecoder().decode(HotKeyShortcut.self, from: data)) ?? .defaultToggle
        case nil:
            toggleShortcut = .defaultToggle
        }
        autoHide = defaults.object(forKey: Key.autoHide) as? Bool ?? true
        let delay = defaults.object(forKey: Key.autoHideDelay) as? Int ?? Self.defaultAutoHideDelay
        autoHideDelay = Self.autoHideDelays.contains(delay) ? delay : Self.defaultAutoHideDelay
        openOnHover = defaults.object(forKey: Key.openOnHover) as? Bool ?? true
        showNowPlaying = defaults.object(forKey: Key.showNowPlaying) as? Bool ?? true
        nowPlayingSource = defaults.string(forKey: Key.nowPlayingSource).flatMap(NowPlayingSource.init(rawValue:)) ?? .any
    }
}

/// De qué apps se muestra lo que suena. El "Ahora suena" de macOS es de una sola app a la vez: con "Solo TIDAL",
/// si un vídeo del navegador se lo quita, la franja desaparece hasta que TIDAL lo recupere
enum NowPlayingSource: String, CaseIterable, Identifiable {
    case any, tidal

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Cualquier app"
        case .tidal: "Solo TIDAL"
        }
    }

    func accepts(_ bundleIdentifier: String) -> Bool {
        self == .any || bundleIdentifier == NowPlaying.tidalBundleID
    }
}

/// Velocidad de las alas al recogerse y volver a salir cuando cambia el escritorio
enum SwitchSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast, instant

    var id: Self { self }

    var title: String {
        switch self {
        case .slow: "Lenta"
        case .normal: "Normal"
        case .fast: "Rápida"
        case .instant: "Sin animación"
        }
    }

    /// Cuántas veces más rápida que la normal; nil, sin animación
    var factor: Double? {
        switch self {
        case .slow: 0.6
        case .normal: 1
        case .fast: 1.6
        case .instant: nil
        }
    }

    /// nil hace el cambio sin animar
    func animation(_ base: Animation) -> Animation? {
        factor.map { base.speed($0) }
    }

    /// Un tiempo de la animación normal a esta velocidad
    func scaled(_ duration: Duration) -> Duration {
        guard let factor else { return .zero }
        return duration * (1 / factor)
    }
}
