import Foundation

// Lógica pura de los sonidos del Pomodoro: se sintetizan en código, sin archivos de audio ni licencias. Son
// instrumentos de percusión suaves, para avisar sin sonar a alarma:
// - aviso (30 s antes): una nota de kalimba, madera y metal, que se apaga en menos de un segundo;
// - fin del foco: un cuenco tibetano grave, con armónicos que no son múltiplos y que vibran un poco entre sí;
// - fin del descanso: dos notas de kalimba que suben.
enum CueSynth {
    enum Cue: CaseIterable {
        case warning, focusEnd, breakEnd
    }

    static let sampleRate = 44_100.0
    /// Pico de cada sonido, con margen para no saturar
    static let peak: Float = 0.7

    /// Un parcial: frecuencia, amplitud y cuánto tarda en apagarse (constante de tiempo, en segundos)
    private struct Partial {
        var frequency: Double
        var amplitude: Double
        var decay: Double
    }

    static func samples(for cue: Cue) -> [Float] {
        switch cue {
        case .warning:
            return normalized(kalimba(frequency: 784, length: 1.4))  // Sol 5
        case .focusEnd:
            return normalized(bowl(frequency: 196, length: 4.5))  // Sol 3
        case .breakEnd:
            // Re 5 y La 5, separadas un poco menos de dos décimas
            var mix = kalimba(frequency: 587.33, length: 1.6)
            let second = kalimba(frequency: 880, length: 1.6 - 0.17)
            let offset = Int(0.17 * sampleRate)
            for index in second.indices { mix[offset + index] += second[index] }
            return normalized(mix)
        }
    }

    // MARK: - Instrumentos

    // La lengüeta de una kalimba: la fundamental, un armónico agudo y no entero que se apaga deprisa (el brillo
    // metálico) y un golpe de ataque muy corto
    private static func kalimba(frequency: Double, length: Double) -> [Float] {
        let partials = [
            Partial(frequency: frequency, amplitude: 1, decay: 0.35),
            Partial(frequency: frequency * 5.95, amplitude: 0.22, decay: 0.07),
            Partial(frequency: frequency * 2.01, amplitude: 0.12, decay: 0.15),
        ]
        return render(partials, length: length, attack: 0.004, beat: 0)
    }

    // Un cuenco tibetano: armónicos inarmónicos con las proporciones típicas de un cuenco, los agudos se apagan
    // antes, y cada uno se suma con una copia un poco desafinada para que "cante" (batidos de 1 a 3 Hz)
    private static func bowl(frequency: Double, length: Double) -> [Float] {
        let partials = [
            Partial(frequency: frequency, amplitude: 1, decay: 2.2),
            Partial(frequency: frequency * 2.76, amplitude: 0.55, decay: 1.4),
            Partial(frequency: frequency * 5.40, amplitude: 0.28, decay: 0.7),
            Partial(frequency: frequency * 8.93, amplitude: 0.12, decay: 0.35),
        ]
        return render(partials, length: length, attack: 0.012, beat: 1.8)
    }

    // Suma los parciales con su caída exponencial, un ataque suave para que no haga clic y un final en rampa para
    // acabar en silencio. Con `beat`, cada parcial lleva una copia desafinada esos hercios
    private static func render(_ partials: [Partial], length: Double, attack: Double, beat: Double) -> [Float] {
        let count = Int(length * sampleRate)
        let fadeOut = 0.25
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / sampleRate
            var value = 0.0
            for partial in partials {
                let envelope = partial.amplitude * exp(-time / partial.decay)
                value += envelope * sin(2 * .pi * partial.frequency * time)
                if beat > 0 {
                    value += envelope * 0.6 * sin(2 * .pi * (partial.frequency + beat) * time)
                }
            }
            let rampIn = min(1, time / attack)
            let rampOut = min(1, (length - time) / fadeOut)
            samples[index] = Float(value * rampIn * rampOut)
        }
        return samples
    }

    private static func normalized(_ samples: [Float]) -> [Float] {
        let loudest = samples.map(abs).max() ?? 0
        guard loudest > 0 else { return samples }
        return samples.map { $0 / loudest * peak }
    }

    // MARK: - WAV

    /// Un WAV PCM de 16 bits y un canal, para reproducirlo con AVAudioPlayer o guardarlo y escucharlo
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))  // tamaño del bloque fmt
        append(UInt16(1))  // PCM
        append(UInt16(1))  // un canal
        append(rate)
        append(rate * 2)  // bytes por segundo
        append(UInt16(2))  // bytes por muestra
        append(UInt16(16))  // bits por muestra
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
