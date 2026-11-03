import Foundation

// Lógica pura de lo que suena en el "Ahora suena" de macOS: la canción, la app que la reproduce y en qué punto va.
struct NowPlaying: Equatable, Sendable {
    static let tidalBundleID = "com.tidal.desktop"

    var bundleIdentifier: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// En segundos; nil si la app no la da (una radio, por ejemplo)
    var duration: TimeInterval?
    /// Lo que llevaba sonando en `timestamp`
    var elapsed: TimeInterval
    var timestamp: Date?
    var playbackRate: Double
    /// Distingue una canción de la siguiente aunque se llamen igual
    var trackID: String?
    var artworkData: Data?

    /// Lo que lleva sonando en `date`, sin preguntar a la app: el adaptador solo avisa de los cambios
    func elapsed(at date: Date) -> TimeInterval {
        var value = elapsed
        if isPlaying, let timestamp {
            value += date.timeIntervalSince(timestamp) * playbackRate
        }
        return min(max(0, value), duration ?? .infinity)
    }

    func isSameTrack(as other: NowPlaying) -> Bool {
        bundleIdentifier == other.bundleIdentifier && (trackID.map { $0 == other.trackID } ?? (title == other.title))
    }
}

// De la salida de mediaremote-adapter (con --micros) a NowPlaying. `stream` manda el estado completo al cambiar
// de canción (diff: false) y luego solo lo que cambia (diff: true), donde un null borra el campo.
struct NowPlayingParser {
    private var payload: [String: Any] = [:]
    private var hasStreamData = false

    var current: NowPlaying? { NowPlaying(adapterPayload: payload) }

    /// La salida de `get`: el estado completo, o null si no suena nada
    mutating func apply(getOutput data: Data) -> NowPlaying? {
        payload = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        return current
    }

    /// Una línea de `stream`. Una línea que no se entiende no cambia nada
    mutating func apply(streamLine data: Data) -> NowPlaying? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let changes = message["payload"] as? [String: Any] else { return current }
        defer { hasStreamData = true }
        if message["diff"] as? Bool == true {
            for (key, value) in changes {
                if value is NSNull {
                    payload.removeValue(forKey: key)
                } else {
                    payload[key] = value
                }
            }
        } else if changes.isEmpty, !hasStreamData {
            // Si lo que suena está en pausa al arrancar, el primer mensaje llega vacío aunque `get` sí lo devuelva:
            // se conserva lo de `get`
        } else {
            payload = changes
        }
        return current
    }
}

extension NowPlaying {
    /// Las claves de mediaremote-adapter con --micros. Sin app, título o estado no hay nada que mostrar
    init?(adapterPayload payload: [String: Any]) {
        guard let bundleIdentifier = payload["bundleIdentifier"] as? String,
              let title = payload["title"] as? String,
              let isPlaying = payload["playing"] as? Bool else { return nil }
        let seconds = { (key: String) in (payload[key] as? Double).map { $0 / 1_000_000 } }
        self.init(
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            isPlaying: isPlaying,
            duration: seconds("durationMicros"),
            elapsed: seconds("elapsedTimeMicros") ?? 0,
            timestamp: seconds("timestampEpochMicros").map(Date.init(timeIntervalSince1970:)),
            playbackRate: payload["playbackRate"] as? Double ?? (isPlaying ? 1 : 0),
            trackID: payload["contentItemIdentifier"] as? String,
            artworkData: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
        )
    }
}
