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

/// Lo que enseña la isla cerrada unos segundos en lugar de los espacios
enum IslandPeek: Equatable {
    /// Canción nueva: la carátula y el título
    case track
    /// El cargador o la batería baja: el símbolo y el porcentaje, sin cambiar el ancho de las alas
    case battery(BatteryEvent, level: Int)
    /// El Pomodoro: la fase que empieza o lo que queda
    case pomodoro(PomodoroPeek)

    /// Cuánto se ve
    var duration: Duration {
        switch self {
        case .track: .seconds(3)
        case .battery(.low, _), .battery(.critical, _): .seconds(5)
        case .battery: .seconds(3)
        case .pomodoro(let peek): if case .warning = peek.kind { .seconds(3) } else { .seconds(4) }
        }
    }

    /// Las alas se abren al máximo para que quepa un título
    var widensWings: Bool {
        switch self {
        case .track, .pomodoro: true
        case .battery: false
        }
    }

    /// Para los logs
    var summary: String {
        switch self {
        case .track: "canción nueva"
        case .battery(let event, let level): "batería \(event) al \(level) %"
        case .pomodoro(let peek): "\(peek.title) · \(peek.subtitle)"
        }
    }

    /// Un aviso no sustituye a otro que se está viendo si es menos importante: el Pomodoro va antes que la
    /// batería, y la batería antes que la canción
    var priority: Int {
        switch self {
        case .track: 0
        case .battery: 1
        case .pomodoro: 2
        }
    }
}
