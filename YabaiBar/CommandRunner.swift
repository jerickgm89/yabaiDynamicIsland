import Foundation
import os

// Ejecuta un programa de línea de comandos fuera del hilo principal, con un tiempo máximo, y devuelve lo que escribe
// por la salida estándar. Lo usan los módulos de Desarrollador (`ps`, y después `lsof`, `docker`, `git` y `gh`).
//
// Pasado el tiempo máximo se le manda SIGTERM y, si lo ignora, SIGKILL un segundo después: `run` siempre vuelve.
// stdout y stderr se leen a la vez, para que ninguno de los dos llene su tubería (unos 64 KB) y bloquee al programa.
// Cuando el programa termina no se espera más de un segundo a que las tuberías se cierren: un proceso hijo que siga
// vivo las mantiene abiertas, y se devuelve lo que ya llegó.
struct CommandRunner: Sendable {
    enum Failure: Error, Equatable {
        case notFound(path: String)
        /// Pasó el tiempo máximo y hubo que pararlo
        case timedOut(command: String)
        /// Salió con error o lo mató una señal ajena (entonces `status` es el número de la señal). `stderr` es lo que
        /// escribió, sin espacios sobrantes
        case failed(command: String, status: Int32, stderr: String)
    }

    let timeout: TimeInterval

    /// Lo que se espera, tras el SIGTERM del tiempo máximo, antes del SIGKILL
    static let killGrace: TimeInterval = 1

    init(timeout: TimeInterval = 2) {
        self.timeout = timeout
    }

    /// `executable` es una ruta absoluta: una app gráfica no hereda el PATH de la shell
    func run(_ executable: String, _ arguments: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notFound(path: executable)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments) })
            }
        }
    }

    // Process bloquea hasta que el programa termina: corre en una cola global, nunca en el hilo principal
    private func runBlocking(_ executable: String, _ arguments: [String]) throws -> String {
        let command = URL(filePath: executable).lastPathComponent
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        // El entorno de la app, que lleva HOME (sin él, `gh` y `git` no encuentran su configuración), pero con los
        // números y los mensajes en el formato de siempre, sin la configuración regional del usuario
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw Failure.failed(command: command, status: -1, stderr: error.localizedDescription)
        }
        // Pasado el tiempo, SIGTERM; si lo ignora, SIGKILL
        let expired = OSAllocatedUnfairLock(initialState: false)
        let terminate = DispatchWorkItem {
            guard process.isRunning else { return }
            expired.withLock { $0 = true }
            process.terminate()
        }
        let kill = DispatchWorkItem {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Self.killGrace, execute: kill)
        // stdout y stderr a la vez
        let stdout = Self.collect(output)
        let stderr = Self.collect(errors)
        process.waitUntilExit()
        terminate.cancel()
        kill.cancel()
        // Un solo segundo para las dos tuberías, no uno para cada una
        let deadline = DispatchTime.now() + 1
        _ = stdout.done.wait(timeout: deadline)
        _ = stderr.done.wait(timeout: deadline)
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil

        if expired.withLock({ $0 }) { throw Failure.timedOut(command: command) }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.data.withLock { $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(command: command, status: process.terminationStatus, stderr: message)
        }
        return String(decoding: stdout.data.withLock { $0 }, as: UTF8.self)
    }

    // Va guardando lo que llega por una tubería hasta que se cierra (`done`), sin bloquear ningún hilo
    private static func collect(_ pipe: Pipe) -> (data: OSAllocatedUnfairLock<Data>, done: DispatchSemaphore) {
        let data = OSAllocatedUnfairLock(initialState: Data())
        let done = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
            } else {
                data.withLock { $0.append(chunk) }
            }
        }
        return (data, done)
    }
}
