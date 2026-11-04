import Foundation
import Testing
@testable import YabaiBar

struct CueSynthTests {
    // Cada sonido dura lo previsto, no satura y empieza y acaba en silencio, sin clics
    @Test(arguments: [(CueSynth.Cue.warning, 1.4), (.focusEnd, 4.5), (.breakEnd, 1.6)])
    func soundsAreCleanAndOfTheRightLength(cue: CueSynth.Cue, seconds: Double) {
        let samples = CueSynth.samples(for: cue)
        #expect(abs(Double(samples.count) / CueSynth.sampleRate - seconds) < 0.01)
        let loudest = samples.map(abs).max() ?? 0
        #expect(abs(loudest - CueSynth.peak) < 0.001)
        #expect(abs(samples.first ?? 1) < 0.01)
        #expect(abs(samples.last ?? 1) < 0.01)
    }

    // 44 bytes de cabecera y 2 por muestra
    @Test func writesAValidWav() {
        let data = CueSynth.wav([0, 0.5, -0.5, 1])
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
    }
}

struct VolumeFadeTests {
    @Test func fadesSmoothlyToTheTarget() {
        let steps = VolumeFade.steps(from: 0.6, to: 0.2, count: 10)
        #expect(steps.count == 10)
        #expect(steps.last == 0.2)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 })
        // Empieza y acaba despacio: el primer paso es más corto que el del medio
        #expect(0.6 - steps[0] < steps[4] - steps[5])
    }

    // Si tocas el volumen mientras está bajado, no se te quita
    @Test func noticesWhenYouTouchTheVolume() {
        #expect(VolumeFade.isUntouched(current: 0.31, lastSet: 0.3))
        #expect(!VolumeFade.isUntouched(current: 0.5, lastSet: 0.3))
    }
}
