import Foundation
import Testing
@testable import YabaiBar

private func track(_ id: String, playing: Bool = true) -> NowPlaying {
    NowPlaying(
        bundleIdentifier: NowPlaying.tidalBundleID, title: "Canción \(id)", artist: "", album: "", isPlaying: playing,
        duration: 200, elapsed: 0, timestamp: nil, playbackRate: playing ? 1 : 0, trackID: id, artworkData: nil
    )
}

// #expect no admite llamadas que mutan: cada test pasa una secuencia y compara lo que avisó
private func changes(_ sequence: [NowPlaying?]) -> [Bool] {
    var detector = TrackChangeDetector()
    return sequence.map { detector.update($0) }
}

struct TrackChangeDetectorTests {
    // Lo que ya sonaba al arrancar la app no es una canción nueva
    @Test func theFirstTrackDoesNotCount() {
        #expect(changes([nil, track("a")]) == [false, false])
    }

    // En pausa no se avisa, y al reanudarla ya no es nueva
    @Test func aNewTrackCountsWhenItPlays() {
        #expect(changes([track("a"), track("b"), track("c", playing: false), track("c")]) == [false, true, false, false])
    }

    // Pausar o un silencio no es una canción nueva; tras un silencio, otra canción sí
    @Test func pausingOrSilenceIsNotANewTrack() {
        let sequence = [track("a"), track("a", playing: false), nil, track("a"), nil, track("b")]
        #expect(changes(sequence) == [false, false, false, false, false, true])
    }
}

// Un gesto de trackpad como lo manda macOS: empieza, cambia varias veces y termina
private func swipe(
    _ deltasX: [CGFloat], deltaY: CGFloat = 0, inverted: Bool = true, tracker: inout SideSwipeTracker
) -> [SideSwipeTracker.Direction] {
    var fired: [SideSwipeTracker.Direction] = []
    for (position, deltaX) in deltasX.enumerated() {
        let sample = SideSwipeTracker.Sample(
            phase: position == 0 ? .began : .changed, deltaX: deltaX, deltaY: deltaY, isDirectionInverted: inverted
        )
        if let direction = tracker.track(sample) { fired.append(direction) }
    }
    _ = tracker.track(.init(phase: .ended, deltaX: 0))
    return fired
}

struct SideSwipeTrackerTests {
    // Con desplazamiento natural, mover los dedos a la izquierda da deltaX negativo; sin él, positivo
    @Test func fingersLeftIsLeftWithAnyScrollDirection() {
        var tracker = SideSwipeTracker()
        #expect(swipe([-10, -20, -15], tracker: &tracker) == [.left])
        #expect(swipe([10, 20, 15], inverted: false, tracker: &tracker) == [.left])
        #expect(swipe([10, 20, 15], tracker: &tracker) == [.right])
    }

    @Test func firesOncePerGesture() {
        var tracker = SideSwipeTracker()
        #expect(swipe([-30, -30, -60, 200], tracker: &tracker) == [.left])
    }

    @Test func ignoresShortAndMostlyVerticalMovements() {
        var tracker = SideSwipeTracker()
        #expect(swipe([-10, -10], tracker: &tracker) == [])
        #expect(swipe([-20, -20, -20], deltaY: 30, tracker: &tracker) == [])
    }

    @Test func ignoresMomentumAndMouseWheels() {
        var tracker = SideSwipeTracker()
        let momentum = (0..<10).map { _ in tracker.track(.init(phase: .none, deltaX: -50, isMomentum: true)) }
        let wheel = (0..<10).map { _ in tracker.track(.init(phase: .none, deltaX: -50, isDirectionInverted: false)) }
        #expect((momentum + wheel).allSatisfy { $0 == nil })
    }
}

private func summary(_ index: Int, apps: Int, focused: Bool = false) -> SpaceSummary {
    SpaceSummary(index: index, isFocused: focused,
                 apps: (0..<apps).map { SpaceApp(pid: Int32(index * 1000 + $0), name: "App\($0)") })
}

struct MusicIndicatorLayoutTests {
    // Ala derecha: 8 + 3 inactivos de 22 + 12 = 86 pt; con las barras, 6 + 14 más
    @Test func theBarsWidenTheWings() {
        let spaces = [summary(1, apps: 1, focused: true), summary(2, apps: 1), summary(3, apps: 0), summary(4, apps: 1)]
        #expect(IslandLayout(spaces: spaces).wingWidth == 86)
        let withMusic = IslandLayout(spaces: spaces, musicIndicator: true)
        #expect(withMusic.showsMusicIndicator)
        #expect(withMusic.wingWidth == 106)
        #expect(withMusic.tokenWidth == IslandLayout.tokenWidth)
    }

    // A pantalla completa la isla mide lo que el notch: sin barras
    @Test func noBarsWhenCollapsed() {
        var fullscreen = summary(1, apps: 1, focused: true)
        fullscreen.isFullscreen = true
        let layout = IslandLayout(spaces: [fullscreen, summary(2, apps: 0)], musicIndicator: true)
        #expect(!layout.showsMusicIndicator)
        #expect(layout.wingWidth == 0)
    }

    @Test func theStripCoversItsWholeArea() {
        let spaces = (1...4).map { summary($0, apps: 0, focused: $0 == 1) }
        let layout = IslandExpandedLayout(spaces: spaces, minBodyWidth: 400, maxBodyWidth: 2000, topHeight: 38, hasMedia: true)
        #expect(layout.mediaStripContains(CGPoint(x: 300, y: 150), islandWidth: 618, topHeight: 38))
        #expect(!layout.mediaStripContains(CGPoint(x: 300, y: 100), islandWidth: 618, topHeight: 38))
    }
}
