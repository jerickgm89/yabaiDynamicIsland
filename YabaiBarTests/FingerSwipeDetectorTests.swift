import Testing
@testable import YabaiBar

// `count` dedos en fila, con el centro en (x, y)
private func fingers(_ count: Int, y: Float, x: Float = 0.5) -> [FingerSwipeDetector.Finger] {
    (0..<count).map { FingerSwipeDetector.Finger(x: x + Float($0) * 0.05, y: y) }
}

// Un gesto completo: los dedos pasan por cada punto y luego se levantan. Devuelve cuántas veces avisó
private func swipe(_ count: Int, through points: [(x: Float, y: Float)], detector: inout FingerSwipeDetector) -> Int {
    var fired = points.filter { detector.track(fingers(count, y: $0.y, x: $0.x)) }.count
    if detector.track([]) { fired += 1 }
    return fired
}

private func down(from start: Float, to end: Float, steps: Int = 10) -> [(x: Float, y: Float)] {
    (0...steps).map { (x: 0.4, y: start + (end - start) * Float($0) / Float(steps)) }
}

struct FingerSwipeDetectorTests {
    @Test(arguments: [3, 4])
    func swipingDownFiresOnce(count: Int) {
        var detector = FingerSwipeDetector()
        #expect(swipe(count, through: down(from: 0.7, to: 0.3), detector: &detector) == 1)
    }

    // Dos dedos son el scroll de todas las apps y cinco, el gesto de Launchpad
    @Test(arguments: [1, 2, 5])
    func otherFingerCountsNeverFire(count: Int) {
        var detector = FingerSwipeDetector()
        #expect(swipe(count, through: down(from: 0.9, to: 0.1), detector: &detector) == 0)
    }

    // Hacia arriba es Mission Control
    @Test func swipingUpNeverFires() {
        var detector = FingerSwipeDetector()
        #expect(swipe(3, through: down(from: 0.2, to: 0.8), detector: &detector) == 0)
    }

    // A los lados se cambia de escritorio, aunque los dedos se desvíen un poco hacia abajo
    @Test func sidewaysSwipesNeverFire() {
        var detector = FingerSwipeDetector()
        let sideways = (0...10).map { (x: 0.2 + 0.06 * Float($0), y: 0.6 - 0.015 * Float($0)) }
        #expect(swipe(4, through: sideways, detector: &detector) == 0)
    }

    @Test func shortMovementsDoNotFire() {
        var detector = FingerSwipeDetector()
        #expect(swipe(3, through: down(from: 0.5, to: 0.45), detector: &detector) == 0)
    }

    // Avisa en cuanto baja lo bastante, sin esperar a que se levanten los dedos
    @Test func firesBeforeTheFingersLift() {
        var detector = FingerSwipeDetector()
        let fired = [0.6, 0.55, 0.48, 0.3].map { detector.track(fingers(3, y: $0)) }
        #expect(fired == [false, false, true, false])
    }

    @Test func eachGestureFiresOnItsOwn() {
        var detector = FingerSwipeDetector()
        #expect(swipe(3, through: down(from: 0.8, to: 0.2), detector: &detector) == 1)
        #expect(swipe(4, through: down(from: 0.8, to: 0.2), detector: &detector) == 1)
        // Lo que bajó un gesto corto no se suma al siguiente
        #expect(swipe(3, through: down(from: 0.5, to: 0.44), detector: &detector) == 0)
        #expect(swipe(3, through: down(from: 0.5, to: 0.44), detector: &detector) == 0)
    }

    // El cuarto dedo llega tarde y más abajo: el salto del centro no es movimiento de los dedos
    @Test func aFingerArrivingMidGestureIsNotMovement() {
        var detector = FingerSwipeDetector()
        let three = fingers(3, y: 0.6)
        let four = three + [FingerSwipeDetector.Finger(x: 0.5, y: 0.1)]
        let fired = [three, four, three].map { detector.track($0) }
        #expect(fired == [false, false, false])
    }
}
