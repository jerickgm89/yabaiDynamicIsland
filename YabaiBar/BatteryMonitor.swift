import Foundation
import IOKit.ps

// Avisa de cada cambio de la batería (el porcentaje y el cargador) con las notificaciones de IOKit, que llegan por
// el run loop principal. API pública y sin permisos. En un Mac sin batería no avisa nunca.
@MainActor
final class BatteryMonitor {
    private let onChange: @MainActor @Sendable (BatteryState) -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping @MainActor @Sendable (BatteryState) -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.notify() }
        }, context)?.takeRetainedValue()
        // En los modos comunes, para que también llegue con un menú abierto
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        // El estado de partida, para que lo primero que cambie se compare con algo
        notify()
    }

    private func notify() {
        if let state = Self.current() { onChange(state) }
    }

    /// La batería interna; nil si no hay
    static func current() -> BatteryState? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return BatteryState(
                level: Int((Double(current) / Double(maximum) * 100).rounded()),
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }
}
