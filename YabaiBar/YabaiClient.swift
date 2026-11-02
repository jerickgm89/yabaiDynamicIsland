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

struct YabaiClient: YabaiQuerying {
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
    private func run(_ args: [String]) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw YabaiError.notInstalled(path: executablePath)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(args) })
            }
        }
    }

    private func runBlocking(_ args: [String]) throws -> Data {
        let command = "yabai -m " + args.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = ["-m"] + args
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
