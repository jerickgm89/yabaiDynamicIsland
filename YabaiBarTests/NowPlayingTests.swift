import Foundation
import Testing
@testable import YabaiBar

// Los 15 mensajes reales de `stream` con TIDAL de la fase 13: reproducir, siguiente, anterior y pausa.
// La carátula es un JPEG mínimo en lugar de la real
private func streamLines() throws -> [Data] {
    let text = try String(contentsOf: Fixture.directory.appending(path: "nowplaying-tidal-stream.jsonl"), encoding: .utf8)
    return text.split(separator: "\n").map { Data($0.utf8) }
}

private func line(_ json: String) -> Data { Data(json.utf8) }

struct NowPlayingParserTests {
    @Test func followsTheRealTidalStream() throws {
        var parser = NowPlayingParser()
        let states = try streamLines().map { parser.apply(streamLine: $0) }
        #expect(states.count == 15)

        // Empieza en pausa: el primer mensaje llega vacío
        #expect(states[0] == nil)
        let first = try #require(states[1])
        #expect(first.bundleIdentifier == NowPlaying.tidalBundleID)
        #expect(first.title == "Mujer Amante (Vivo)")
        #expect(first.artist == "Rata Blanca")
        #expect(first.isPlaying)
        #expect(first.elapsed == 29.187)
        #expect(first.duration == 377.399)
        // La carátula llega en el mensaje siguiente
        #expect(first.artworkData == nil)
        #expect(states[2]?.artworkData != nil)

        // Siguiente canción: llega entera y sin la carátula de la anterior
        let next = try #require(states[6])
        #expect(next.title == "Like a Stone")
        #expect(next.artworkData == nil)
        #expect(!next.isSameTrack(as: first))
        #expect(states[7]?.artworkData != nil)

        // Termina en pausa al principio de la primera
        let last = try #require(states[14])
        #expect(last.title == "Mujer Amante (Vivo)")
        #expect(!last.isPlaying)
        #expect(last.playbackRate == 0)
        #expect(last.elapsed == 3.111)
    }

    @Test func keepsWhatGetReturnedWhenTheStreamStartsEmpty() {
        var parser = NowPlayingParser()
        let get = line(#"{"bundleIdentifier":"com.tidal.desktop","title":"Uno","playing":false,"elapsedTimeMicros":5000000}"#)
        #expect(parser.apply(getOutput: get)?.title == "Uno")
        #expect(parser.apply(streamLine: line(#"{"type":"data","diff":false,"payload":{}}"#))?.title == "Uno")
        // Después, un mensaje vacío sí significa que ya no suena nada
        #expect(parser.apply(streamLine: line(#"{"type":"data","diff":false,"payload":{}}"#)) == nil)
    }

    @Test func aNullInADiffRemovesTheField() {
        var parser = NowPlayingParser()
        _ = parser.apply(streamLine: line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"T","playing":true,"artist":"A"}}"#))
        let state = parser.apply(streamLine: line(#"{"type":"data","diff":true,"payload":{"artist":null}}"#))
        #expect(state?.artist == "")
        #expect(state?.title == "T")
    }

    @Test func ignoresLinesItDoesNotUnderstand() {
        var parser = NowPlayingParser()
        _ = parser.apply(streamLine: line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"a","title":"T","playing":true}}"#))
        #expect(parser.apply(streamLine: line("esto no es JSON"))?.title == "T")
        #expect(parser.apply(getOutput: line("null")) == nil)
    }
}

struct NowPlayingTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func track(playing: Bool, elapsed: TimeInterval = 10, duration: TimeInterval? = 100) -> NowPlaying {
        NowPlaying(
            bundleIdentifier: "a", title: "T", artist: "", album: "", isPlaying: playing, duration: duration,
            elapsed: elapsed, timestamp: start, playbackRate: playing ? 1 : 0, trackID: "1", artworkData: nil
        )
    }

    // El adaptador solo avisa de los cambios: el tiempo se calcula desde el último aviso
    @Test func elapsedTimeAdvancesOnlyWhilePlaying() {
        #expect(track(playing: true).elapsed(at: start + 5) == 15)
        #expect(track(playing: false).elapsed(at: start + 5) == 10)
    }

    @Test func elapsedTimeStaysWithinTheTrack() {
        #expect(track(playing: true, elapsed: 98).elapsed(at: start + 10) == 100)
        #expect(track(playing: true, duration: nil).elapsed(at: start + 500) == 510)
    }
}

// Cuatro espacios: cuerpo de 580 pt (isla de 618 con las esquinas) y fila de 552 pt que empieza en x = 33 y va de
// y = 126 a 222. Sola, la música ocupa toda la fila: la carátula en 33–119 y los botones a la derecha, centrados en
// alto (y = 159–189): anterior en 483–513, reproducir en 519–549 y siguiente en 555–585
struct MediaStripLayoutTests {
    private func layout(hasMedia: Bool = true) -> IslandExpandedLayout {
        let spaces = (1...4).map { SpaceSummary(index: $0, isFocused: $0 == 1, apps: []) }
        return IslandExpandedLayout(spaces: spaces, minBodyWidth: 400, maxBodyWidth: 2000, topHeight: 38, hasMedia: hasMedia)
    }

    private func control(_ x: CGFloat, _ y: CGFloat = 174, hasMedia: Bool = true) -> IslandExpandedLayout.Control? {
        layout(hasMedia: hasMedia).control(at: CGPoint(x: x, y: y), islandWidth: 618, topHeight: 38)
    }

    @Test func theRowMakesTheIslandTaller() {
        #expect(layout(hasMedia: false).height == 130)
        #expect(layout().height == 236)
        #expect(layout().mediaWidth == 552)
        #expect(layout().musicSection == CGRect(x: 0, y: 0, width: 552, height: 96))
    }

    @Test func findsEachControl() {
        #expect(control(60, 150) == .artwork)
        #expect(control(498) == .previous)
        #expect(control(534) == .playPause)
        #expect(control(570) == .next)
    }

    @Test func textAndOutsideAreNotControls() {
        #expect(control(300) == nil)
        #expect(control(20) == nil)
        #expect(control(534, 120) == nil)
        #expect(control(534, 200) == nil)
        #expect(control(534, hasMedia: false) == nil)
    }
}
