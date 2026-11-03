import Foundation
import IOKit.pwr_mgt
import Observation
import os

// Mantiene el Mac despierto con una aserción de IOKit, como `caffeinate -d`: ni la pantalla ni el sistema se
// duermen por inactividad. Dura hasta que se apaga; si la app termina, macOS suelta la aserción solo.
@MainActor
@Observable
final class KeepAwake {
    private(set) var isActive = false

    @ObservationIgnored private var assertion: IOPMAssertionID = 0

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        // kIOPMAssertPreventUserIdleDisplaySleep es un CFSTR de C, que Swift no importa
        let status = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "YabaiBar: mantener despierto" as CFString, &assertion
        )
        guard status == kIOReturnSuccess else {
            Logger.app.error("Mantener despierto: IOKit devolvió \(status)")
            return
        }
        isActive = true
        Logger.app.info("Mantener despierto: activado")
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertion)
        isActive = false
        Logger.app.info("Mantener despierto: desactivado")
    }
}
