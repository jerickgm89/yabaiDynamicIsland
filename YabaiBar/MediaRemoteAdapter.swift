import Foundation
import os

// Ejecuta mediaremote-adapter, que lee y controla el "Ahora suena" de macOS. Desde macOS 15.4, MediaRemote solo
// responde a procesos de Apple: el adaptador lo usa desde /usr/bin/perl (que macOS identifica como com.apple.perl5)
// con un framework propio que va dentro de la app. Lo usan también Atoll y boring.notch.
struct MediaRemoteAdapter: Sendable {
    /// Los ids de MRCommand que acepta `send`
    enum Command: Int, Sendable {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private static let perl = URL(filePath: "/usr/bin/perl")
    /// TIDAL mezcla un momento datos de la canción anterior y la siguiente; el adaptador recomienda esperar 1 s
    private static let streamArguments = [
        "stream", "--micros", "--experimental-peculiar-debounce:\(NowPlaying.tidalBundleID)=1000",
    ]

    let scriptPath: String
    let frameworkPath: String
    let timeout: TimeInterval

    /// nil si la app no trae el adaptador
    init?(bundle: Bundle = .main, timeout: TimeInterval = 3) {
        guard let scriptPath = bundle.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let frameworks = bundle.privateFrameworksPath else { return nil }
        let frameworkPath = frameworks + "/MediaRemoteAdapter.framework"
        guard FileManager.default.fileExists(atPath: frameworkPath) else { return nil }
        self.scriptPath = scriptPath
        self.frameworkPath = frameworkPath
        self.timeout = timeout
    }

    /// Lo que suena ahora, en el formato de `get`
    func get() async throws -> Data {
        try await run(["get", "--micros"])
    }

    func send(_ command: Command) async throws {
        _ = try await run(["send", String(command.rawValue)])
    }

    /// Una línea JSON por cada cambio. El proceso sigue mientras alguien recorra la secuencia: al cancelar la
    /// tarea que la recorre, se termina. Si el adaptador falla, la secuencia acaba con el error
    func stream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let process = makeProcess(Self.streamArguments)
            let output = Pipe()
            let errorOutput = Pipe()
            process.standardOutput = output
            process.standardError = errorOutput
            // stderr se va leyendo para que no se llene el pipe y bloquee al adaptador; sus errores no son graves
            errorOutput.fileHandleForReading.readabilityHandler = { handle in
                let text = String(decoding: handle.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { Logger.media.error("mediaremote-adapter: \(text, privacy: .public)") }
            }
            let reader = Task.detached { [frameworkPath] in
                do {
                    Self.endOrphans(of: frameworkPath)
                    try process.run()
                    for try await line in output.fileHandleForReading.bytes.lines {
                        continuation.yield(Data(line.utf8))
                    }
                    process.waitUntilExit()
                    errorOutput.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus != 0, process.terminationReason == .exit {
                        throw Failure(status: process.terminationStatus, message: "el stream terminó")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    // Si YabaiBar se cierra sin avisar (pkill, un cierre inesperado, el fin de los tests), el adaptador sigue vivo,
    // adoptado por launchd, hasta que intenta escribir el siguiente cambio. Al arrancar se terminan los de esta
    // copia de la app que ya no tienen padre; los de otra copia (build/ o /Applications) no se tocan
    private static func endOrphans(of frameworkPath: String) {
        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", NSRegularExpression.escapedPattern(for: frameworkPath)]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = Self.perl
        // Rutas absolutas, como pide el adaptador
        process.arguments = [scriptPath, frameworkPath] + arguments
        return process
    }

    // Como en YabaiClient: Process bloquea hasta que termina, así que corre en una cola global y con un límite de tiempo
    private func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments) })
            }
        }
    }

    private func runBlocking(_ arguments: [String]) throws -> Data {
        let process = makeProcess(arguments)
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { throw Self.failure(process, errorOutput) }
        return data
    }

    struct Failure: Error, CustomStringConvertible {
        let status: Int32
        let message: String
        var description: String { "mediaremote-adapter salió con \(status): \(message)" }
    }

    // Cada línea de stderr es un error; con salida 0 no son graves
    private static func failure(_ process: Process, _ errorOutput: Pipe) -> Failure {
        let stderr = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Failure(status: process.terminationStatus, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
