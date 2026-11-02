import Foundation
import ServiceManagement
import os

// Inicio al arrancar con SMAppService. Solo se ofrece desde /Applications: registrar la copia de
// build/ dejaría un ítem de inicio apuntando a una compilación de desarrollo
struct LaunchAtLogin {
    var isAvailable: Bool {
        Bundle.main.bundleURL.path(percentEncoded: false).hasPrefix("/Applications/")
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Logger.app.error("Inicio al arrancar: \(error.localizedDescription, privacy: .public)")
        }
        // macOS puede pedir que el usuario lo apruebe en Ajustes › General › Ítems de inicio
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        Logger.app.info("Inicio al arrancar: \(Self.describe(service.status), privacy: .public)")
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "activado"
        case .notRegistered: "desactivado"
        case .requiresApproval: "pendiente de aprobación en Ajustes"
        case .notFound: "no encontrado"
        @unknown default: "desconocido"
        }
    }
}
