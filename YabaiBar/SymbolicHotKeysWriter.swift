import Foundation
import os

// Añade atajos «Ir al escritorio N» a las preferencias de macOS (com.apple.symbolichotkeys) y hace que valgan sin
// cerrar sesión con `activateSettings -u`, lo mismo que hace Ajustes del Sistema. Solo añade entradas: nunca cambia
// ni borra las que ya están. Antes de la primera escritura copia el plist tal como estaba, y sin esa copia no escribe.
struct SymbolicHotKeysWriter: Sendable {
    enum WriteError: Error, Equatable {
        /// No se pudo copiar el plist antes de tocarlo: no se ha cambiado nada
        case noBackup(String)
        /// macOS no guardó las preferencias
        case notSaved
        /// Se guardaron, pero `activateSettings` falló o tardó demasiado: valdrán al cerrar sesión o al abrir
        /// Ajustes › Teclado
        case notApplied(status: Int32, message: String)
    }

    static let domain = "com.apple.symbolichotkeys"
    static let key = "AppleSymbolicHotKeys"
    static let activateSettings = URL(
        fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    )
    /// Lo que se espera a `activateSettings`, una herramienta privada que una actualización de macOS podría colgar
    static let activateTimeout: TimeInterval = 5
    static let preferencesFile = URL.libraryDirectory.appending(path: "Preferences/\(domain).plist")
    /// La copia de antes de que YabaiBar tocara nada; no se sobrescribe
    static let backupFile = URL.libraryDirectory.appending(path: "Preferences/\(domain).plist.bak-yabaibar")

    /// Escribe las que aún valen (el usuario pudo cambiar sus atajos mientras el aviso estaba abierto) y las devuelve
    func add(
        _ proposals: [DesktopShortcuts.Proposal], reserved: Set<DesktopShortcuts.Combination> = []
    ) async throws(WriteError) -> [DesktopShortcuts.Proposal] {
        try Self.backUpOnce()
        let current = ShortcutFocuser.currentHotkeys()
        let valid = DesktopShortcuts.stillValid(proposals, in: current, reserved: reserved)
        guard !valid.isEmpty else { return [] }
        let updated = DesktopShortcuts.adding(valid, to: current)
        CFPreferencesSetAppValue(Self.key as CFString, updated as CFDictionary, Self.domain as CFString)
        guard CFPreferencesAppSynchronize(Self.domain as CFString) else { throw .notSaved }
        let saved = ShortcutFocuser.currentHotkeys()
        guard valid.allSatisfy({ ShortcutFocuser.shortcut(forDesktop: $0.desktop, in: saved) != nil }) else {
            throw .notSaved
        }
        let (status, message) = await Self.run(Self.activateSettings, arguments: ["-u"], timeout: Self.activateTimeout)
        guard status == 0 else { throw .notApplied(status: status, message: message) }
        Logger.app.info("Atajos de escritorio añadidos: \(valid.map(\.label).joined(separator: " "), privacy: .public)")
        return valid
    }

    private static func backUpOnce() throws(WriteError) {
        let files = FileManager.default
        guard files.fileExists(atPath: preferencesFile.path(percentEncoded: false)),
              !files.fileExists(atPath: backupFile.path(percentEncoded: false)) else { return }
        do {
            try files.copyItem(at: preferencesFile, to: backupFile)
            Logger.app.info("Copia de los atajos de macOS: \(backupFile.path(percentEncoded: false), privacy: .public)")
        } catch {
            throw .noBackup(error.localizedDescription)
        }
    }

    // El código de salida y lo que escribió en stderr; -1 si no se pudo ejecutar. Process bloquea, así que corre en
    // una cola global, con un vigilante que lo termina si tarda demasiado (como YabaiClient)
    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                let errorOutput = Pipe()
                process.standardError = errorOutput
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let message = process.terminationReason == .uncaughtSignal
                    ? "no respondió en \(Int(timeout)) s"
                    : String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationReason == .uncaughtSignal ? -1 : process.terminationStatus, message))
            }
        }
    }
}
