import AVFoundation
import Observation
import os

// Toca los sonidos del Pomodoro (ver CueSynth). Se sintetizan una vez, fuera del hilo principal, al arrancar
@MainActor
final class CuePlayer {
    private var sounds: [CueSynth.Cue: Data] = [:]
    /// Los que están sonando: AVAudioPlayer se calla si nadie lo retiene
    private var playing: [AVAudioPlayer] = []

    init() {
        Task { [weak self] in
            let rendered = await Task.detached {
                Dictionary(uniqueKeysWithValues: CueSynth.Cue.allCases.map { ($0, CueSynth.wav(CueSynth.samples(for: $0))) })
            }.value
            self?.sounds = rendered
        }
    }

    func play(_ cue: CueSynth.Cue) {
        playing.removeAll { !$0.isPlaying }
        guard let data = sounds[cue], let player = try? AVAudioPlayer(data: data) else { return }
        player.play()
        playing.append(player)
        Logger.app.info("Sonido: \(String(describing: cue), privacy: .public)")
    }
}

// Lo que suena y lo que hace la música en cada evento del Pomodoro. Con música sonando:
// - 30 s antes del final, suena la kalimba y, medio segundo después, el volumen baja poco a poco y se queda bajo;
// - al terminar, el volumen vuelve (deprisa, para que el sonido se oiga como el primero) y suena el cuenco al acabar
//   el foco o las dos notas al acabar el descanso.
// Si pausas, saltas o terminas con el volumen bajado, vuelve también. Sin música, solo los sonidos.
@MainActor
final class PomodoroCue {
    static let duckDelay: Duration = .milliseconds(500)
    static let duckDuration: Duration = .seconds(2)
    static let restoreDuration: Duration = .milliseconds(700)

    private let settings: AppSettings
    private let media: NowPlayingStore
    private let pomodoro: PomodoroStore
    private let ducker: VolumeDucker
    private let player: CuePlayer
    /// La fase en la que se bajó el volumen: si deja de correr sin terminar, el volumen vuelve
    private var duckedPhase: PomodoroPhase?
    private var duckTask: Task<Void, Never>?

    init(settings: AppSettings, media: NowPlayingStore, pomodoro: PomodoroStore, ducker: VolumeDucker, player: CuePlayer) {
        self.settings = settings
        self.media = media
        self.pomodoro = pomodoro
        self.ducker = ducker
        self.player = player
        observeTimer()
    }

    func handle(_ event: PomodoroEvent) {
        switch event {
        case .warning(let phase):
            if settings.pomodoroSound { player.play(.warning) }
            guard settings.pomodoroDuckMusic, media.nowPlaying?.isPlaying == true else { return }
            duckedPhase = phase
            duckTask = Task { [weak self] in
                try? await Task.sleep(for: Self.duckDelay)
                guard let self, !Task.isCancelled else { return }
                ducker.duck(to: Double(settings.pomodoroDuckLevel) / 100, over: Self.duckDuration)
            }
        case .finished(let phase, _):
            Task {
                await restore()
                if settings.pomodoroSound { player.play(phase == .focus ? .focusEnd : .breakEnd) }
            }
        }
    }

    /// Al salir de la app, el volumen vuelve de golpe
    func restoreNow() {
        duckTask?.cancel()
        ducker.restoreNow()
    }

    private func restore() async {
        duckTask?.cancel()
        duckedPhase = nil
        await ducker.restore(over: Self.restoreDuration)
    }

    // Pausar, saltar o terminar con el volumen bajado: vuelve. El fin normal de la fase lo resuelve handle()
    private func observeTimer() {
        let timer = withObservationTracking {
            pomodoro.timer
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTimer() }
        }
        guard let duckedPhase, !timer.isRunning || timer.phase != duckedPhase else { return }
        Task { await restore() }
    }
}
