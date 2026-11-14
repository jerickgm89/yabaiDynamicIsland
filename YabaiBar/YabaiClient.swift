import Foundation
import os

enum YabaiError: Error, Equatable {
    case notInstalled(path: String)
    case notRunning
    case timedOut(command: String)
    case commandFailed(command: String, stderr: String)
    case decoding(String)
}

protocol YabaiQuerying: Sendable {
    func spaces() async throws -> [YabaiSpace]
    func windows() async throws -> [YabaiWindow]
}

/// Lo que la isla le pide a yabai. En los tests, uno falso que apunta las acciones
protocol YabaiControlling: Sendable {
    func perform(_ action: YabaiAction) async throws
}

struct YabaiClient: YabaiQuerying, YabaiControlling {
    static let candidatePaths = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]

    let executablePath: String
    let timeout: TimeInterval

    init(executablePath: String? = nil, timeout: TimeInterval = 2) {
        self.executablePath = executablePath ?? Self.resolvedPath()
        self.timeout = timeout
    }

    // Las apps gráficas no heredan el PATH de la shell: ruta absoluta, con override en UserDefaults
    static func resolvedPath() -> String {
        let fileManager = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "yabaiPath"),
           fileManager.isExecutableFile(atPath: custom) {
            return custom
        }
        return candidatePaths.first { fileManager.isExecutableFile(atPath: $0) } ?? candidatePaths[0]
    }

    func spaces() async throws -> [YabaiSpace] {
        try await query("--spaces")
    }

    func windows() async throws -> [YabaiWindow] {
        try await query("--windows")
    }

    /// Hace lo que se pide, orden a orden: si una falla (y no es opcional), no se siguen. Si la primera falla y la acción tiene alternativa
    /// (la pila no da la vuelta sola), se prueba esa
    func perform(_ action: YabaiAction) async throws {
        do {
            try await runCommands(action.commands)
        } catch let error as YabaiError {
            guard case .commandFailed = error, let fallback = action.fallback else { throw error }
            try await runCommands(fallback.commands)
        }
    }

    private func runCommands(_ commands: [YabaiCommand]) async throws {
        for command in commands {
            do {
                _ = try await run(command.arguments)
            } catch let error as YabaiError {
                // Una opcional que falla porque yabai dice que no (quitar lo que no estaba) no corta la acción; si yabai no responde, sí
                if command.optional, case .commandFailed = error { continue }
                throw error
            }
        }
    }

    /// `yabai --version`: «yabai-v7.1.25»
    func version() async throws -> String {
        String(decoding: try await run(["--version"], direct: true), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `yabai --restart-service`: reinicia a yabai. Cambia el estado: solo con la confirmación del usuario
    func restartService() async throws {
        _ = try await run(["--restart-service"], direct: true)
    }

    /// `yabai -m rule --list`: las etiquetas de las reglas que tiene yabai ahora
    func ruleLabels() async throws -> [String] {
        struct Rule: Decodable { let label: String? }
        let data = try await run(["rule", "--list"])
        do {
            return try JSONDecoder().decode([Rule].self, from: data).compactMap(\.label)
        } catch {
            throw YabaiError.decoding(String(describing: error))
        }
    }

    /// `yabai -m signal …`: lo usa YabaiSignals para añadir y quitar las señales de YabaiBar
    func signal(_ arguments: [String]) async throws {
        _ = try await run(["signal"] + arguments)
    }

    /// Las etiquetas de las señales que tiene yabai ahora (`yabai -m signal --list`)
    func signalLabels() async throws -> [String] {
        struct Signal: Decodable { let label: String }
        let data = try await run(["signal", "--list"])
        do {
            return try JSONDecoder().decode([Signal].self, from: data).map(\.label)
        } catch {
            throw YabaiError.decoding(String(describing: error))
        }
    }

    private func query<T: Decodable>(_ domain: String) async throws -> T {
        let data = try await run(["query", domain])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw YabaiError.decoding(String(describing: error))
        }
    }

    // Process bloquea hasta que yabai termina, así que corre en una cola global. En el hilo
    // principal waitUntilExit además hace girar el run loop y permite que entre otro refresco.
    private func run(_ args: [String], direct: Bool = false) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw YabaiError.notInstalled(path: executablePath)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(args, direct: direct) })
            }
        }
    }

    // `direct`: las opciones de yabai que no son mensajes (`--version`, `--restart-service`), sin el `-m`
    private func runBlocking(_ args: [String], direct: Bool) throws -> Data {
        let command = (direct ? "yabai " : "yabai -m ") + args.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = (direct ? [] : ["-m"]) + args
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            throw YabaiError.commandFailed(command: command, stderr: error.localizedDescription)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // yabai escribe muy poco en stderr: leer stdout primero no llega a llenar el otro pipe
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw YabaiError.timedOut(command: command)
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("failed to connect to socket") { throw YabaiError.notRunning }
            throw YabaiError.commandFailed(command: command, stderr: message)
        }
        return data
    }
}
