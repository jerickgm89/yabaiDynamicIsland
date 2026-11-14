import Foundation

/// La batería en un momento: el porcentaje y si está enchufada
struct BatteryState: Equatable, Sendable {
    var level: Int
    var isPluggedIn: Bool
    var isCharging: Bool
}

enum BatteryEvent: Equatable, Sendable {
    case pluggedIn, unplugged, low, critical
}

// Lógica pura de los avisos de batería: al enchufar o desenchufar el cargador, y al bajar del 20 % y del 10 % sin
// cargador. Lo primero que llega al arrancar no avisa, y cada umbral avisa una vez al cruzarlo.
struct BatteryEventDetector {
    static let lowLevel = 20
    static let criticalLevel = 10

    private var last: BatteryState?

    mutating func update(_ state: BatteryState) -> BatteryEvent? {
        defer { last = state }
        guard let last else { return nil }
        if state.isPluggedIn != last.isPluggedIn { return state.isPluggedIn ? .pluggedIn : .unplugged }
        guard !state.isPluggedIn else { return nil }
        if last.level > Self.criticalLevel, state.level <= Self.criticalLevel { return .critical }
        if last.level > Self.lowLevel, state.level <= Self.lowLevel { return .low }
        return nil
    }
}

/// Un aviso genérico de la isla cerrada: un símbolo, un título y un detalle. Lo usan Git (fase 40) y, después, la terminal
struct IslandNotice: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case info, ok, warning, error }

    var symbol: String
    var tone: Tone
    var title: String
    var subtitle: String
    /// Un error se ve más tiempo
    var isUrgent = false
    /// Más importante, más arriba (ver `IslandPeek.priority`)
    var priority = 20
}

/// Lo que enseña la isla cerrada unos segundos en lugar de los espacios
enum IslandPeek: Equatable {
    /// Canción nueva: la carátula y el título
    case track
    /// El cargador o la batería baja: el símbolo y el porcentaje, sin cambiar el ancho de las alas
    case battery(BatteryEvent, level: Int)
    /// El Pomodoro: la fase que empieza o lo que queda
    case pomodoro(PomodoroPeek)
    /// Atajos de escritorio añadidos: «Escritorio 5 · Atajo ⌥5»
    case shortcuts(title: String, subtitle: String)
    /// Una sesión de Claude Code pregunta o terminó
    case claude(ClaudePeek)
    /// Un aviso de Git (o de la terminal): ícono, título y detalle
    case notice(IslandNotice)

    /// Cuánto se ve
    var duration: Duration {
        switch self {
        case .track, .shortcuts: .seconds(3)
        case .claude(let peek): peek.kind == .asks ? .seconds(8) : .seconds(5)
        case .notice(let notice): notice.isUrgent ? .seconds(8) : .seconds(5)
        case .battery(.low, _), .battery(.critical, _): .seconds(5)
        case .battery: .seconds(3)
        case .pomodoro(let peek):
            switch peek.kind {
            case .started, .ready: .seconds(4)
            case .warning, .paused, .resumed: .seconds(3)
            }
        }
    }

    /// Las alas se abren al máximo para que quepa un título
    var widensWings: Bool {
        switch self {
        case .track, .pomodoro, .shortcuts, .claude, .notice: true
        case .battery: false
        }
    }

    /// Para los logs
    var summary: String {
        switch self {
        case .track: "canción nueva"
        case .battery(let event, let level): "batería \(event) al \(level) %"
        case .pomodoro(let peek): "\(peek.title) · \(peek.subtitle)"
        case .shortcuts(let title, let subtitle): "\(title) · \(subtitle)"
        // Sin la carpeta ni el mensaje: son del usuario
        case .claude(let peek): peek.kind == .asks ? "Claude pregunta" : "Claude terminó"
        // Solo el ícono: el título y el detalle llevan nombres de repositorios y de etiquetas
        case .notice(let notice): "aviso «\(notice.symbol)»"
        }
    }

    /// Un aviso no sustituye a otro que se está viendo si es menos importante: una pregunta de Claude va antes que todo (hay
    /// algo parado esperándote), después el Pomodoro, los avisos de Git y de la terminal (y, más adelante, el calendario, entre
    /// ellos y el Pomodoro), la batería y la canción. Con huecos, para ir metiendo los que faltan
    var priority: Int {
        switch self {
        case .track: 0
        case .battery, .shortcuts: 10
        case .notice(let notice): notice.priority
        case .pomodoro: 40
        case .claude(let peek): peek.kind == .asks ? 50 : 10
        }
    }
}
