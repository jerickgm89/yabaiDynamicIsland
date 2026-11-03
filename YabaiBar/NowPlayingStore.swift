import AppKit
import Observation
import os

// Lo que suena, publicado para la isla. Escucha al adaptador mientras el ajuste lo pida, filtra por app y manda
// los botones de la isla. Si el adaptador falla no se reintenta (lo pide su README): apagar y encender el ajuste
// lo vuelve a arrancar.
@MainActor
@Observable
final class NowPlayingStore {
    /// Al cambiar de canción, TIDAL dice "en pausa" un instante: las pausas más cortas que esto no se muestran
    static let pauseGrace: Duration = .milliseconds(1200)

    /// nil si no suena nada, si la app no está permitida o si el ajuste está apagado
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var sourceIcon: NSImage?

    @ObservationIgnored private let adapter: MediaRemoteAdapter?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    /// Lo último que dijo el adaptador, sin filtrar
    @ObservationIgnored private var latest: NowPlaying?

    init(adapter: MediaRemoteAdapter?, settings: AppSettings) {
        self.adapter = adapter
        self.settings = settings
        if adapter == nil { Logger.media.error("Música: la app no trae mediaremote-adapter") }
        observeSettings()
    }

    func togglePlayPause() {
        guard var shown = nowPlaying else { return }
        send(.togglePlayPause)
        // Se ve al momento; el adaptador lo confirma enseguida
        let now = Date()
        shown.elapsed = shown.elapsed(at: now)
        shown.timestamp = now
        shown.isPlaying.toggle()
        shown.playbackRate = shown.isPlaying ? 1 : 0
        pauseTask?.cancel()
        nowPlaying = shown
    }

    /// Al salir de la app: termina el adaptador en vez de dejarlo huérfano
    func shutDown() { stop() }

    func nextTrack() { send(.nextTrack) }

    func previousTrack() { send(.previousTrack) }

    /// Trae al frente la app que suena
    func openSource() {
        guard let bundleID = nowPlaying?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // withObservationTracking avisa una sola vez: se vuelve a registrar en el siguiente ciclo
    private func observeSettings() {
        let enabled = withObservationTracking {
            _ = settings.nowPlayingSource
            return settings.showNowPlaying
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        if enabled { start() } else { stop() }
        publish(latest)
    }

    private func start() {
        guard streamTask == nil, let adapter else { return }
        Logger.media.info("Música: escuchando el Ahora suena")
        streamTask = Task { [weak self] in
            var parser = NowPlayingParser()
            // Si lo que suena está en pausa, el stream no lo manda al arrancar
            if let data = try? await adapter.get() { self?.receive(parser.apply(getOutput: data)) }
            do {
                for try await line in adapter.stream() {
                    self?.receive(parser.apply(streamLine: line))
                }
            } catch {
                Logger.media.error("Música: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func stop() {
        guard let streamTask else { return }
        // Al cancelar la tarea se termina el proceso del adaptador
        streamTask.cancel()
        self.streamTask = nil
        pauseTask?.cancel()
        latest = nil
        Logger.media.info("Música: sin escuchar")
    }

    private func receive(_ value: NowPlaying?) {
        latest = value
        pauseTask?.cancel()
        if let value, !value.isPlaying, let shown = nowPlaying, shown.isPlaying {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: Self.pauseGrace)
                guard !Task.isCancelled, let self else { return }
                publish(latest)
            }
            return
        }
        publish(value)
    }

    private func publish(_ value: NowPlaying?) {
        let visible = value.flatMap { settings.showNowPlaying && settings.nowPlayingSource.accepts($0.bundleIdentifier) ? $0 : nil }
        guard visible != nowPlaying else { return }
        if visible?.artworkData != nowPlaying?.artworkData {
            artwork = visible?.artworkData.flatMap(NSImage.init(data:))
        }
        if visible?.bundleIdentifier != nowPlaying?.bundleIdentifier {
            sourceIcon = visible.flatMap { Self.icon(for: $0.bundleIdentifier) }
        }
        if let visible, nowPlaying.map(visible.isSameTrack(as:)) != true {
            Logger.media.info("Música: canción nueva en \(visible.bundleIdentifier, privacy: .public)")
        }
        nowPlaying = visible
    }

    private func send(_ command: MediaRemoteAdapter.Command) {
        guard let adapter else { return }
        Task.detached {
            do {
                try await adapter.send(command)
            } catch {
                Logger.media.error("Música: no se pudo mandar \(command.rawValue): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
    }
}
