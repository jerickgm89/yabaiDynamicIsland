import Foundation
import Testing
@testable import YabaiBar

// Lo que se lee del sistema de verdad: solo se comprueban límites, no valores
struct SystemReaderTests {
    @Test func memoryIsAPlausibleShareOfThePhysicalMemory() throws {
        let memory = try #require(SystemReader.memory())
        #expect(memory.usedBytes > 0)
        #expect(memory.usedBytes <= memory.totalBytes)
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
    }

    @Test func theCPUCountersOnlyGoForward() async throws {
        let first = try #require(SystemReader.cpuTicks())
        try await Task.sleep(for: .milliseconds(250))
        let second = try #require(SystemReader.cpuTicks())
        #expect(second.total > first.total)
        if let usage = CPUTicks.usage(from: first, to: second) {
            #expect((0...100).contains(usage))
        }
    }
}

struct CommandRunnerTests {
    private let runner = CommandRunner(timeout: 0.5)

    @Test func returnsStandardOutput() async throws {
        #expect(try await runner.run("/bin/echo", ["hola"]) == "hola\n")
    }

    // Lo que escribe por stderr no se mezcla con la salida
    @Test func standardErrorIsNotMixedIntoTheOutput() async throws {
        #expect(try await runner.run("/bin/sh", ["-c", "echo error >&2; echo salida"]) == "salida\n")
    }

    // Sin la configuración regional del usuario, los números salen con punto decimal; pero el resto del entorno se
    // conserva: sin HOME, `gh` y `git` no encuentran su configuración
    @Test func runsWithTheCLocaleAndKeepsTheRestOfTheEnvironment() async throws {
        let environment = try await runner.run("/usr/bin/env", [])
        #expect(environment.contains("LC_ALL=C"))
        #expect(environment.contains("HOME="))
        #expect(environment.contains("PATH="))
    }

    // Si stderr se leyera después de stdout, 300 KB llenarían su tubería y el programa se quedaría bloqueado
    @Test func aProgramThatFillsStandardErrorDoesNotBlock() async throws {
        let output = try await CommandRunner(timeout: 5).run("/bin/sh", ["-c", "head -c 300000 /dev/zero >&2; echo listo"])
        #expect(output == "listo\n")
    }

    @Test func aMissingProgramIsReported() async {
        await #expect(throws: CommandRunner.Failure.notFound(path: "/no/existe")) {
            try await runner.run("/no/existe", [])
        }
    }

    @Test func aFailingProgramReportsItsStatusAndItsMessage() async {
        await #expect(throws: CommandRunner.Failure.failed(command: "sh", status: 3, stderr: "")) {
            try await runner.run("/bin/sh", ["-c", "exit 3"])
        }
        await #expect(throws: CommandRunner.Failure.failed(command: "sh", status: 2, stderr: "se rompió")) {
            try await runner.run("/bin/sh", ["-c", "echo ' se rompió ' >&2; exit 2"])
        }
    }

    // Una señal ajena no es un tiempo agotado: el estado es el número de la señal
    @Test func aProgramKilledBySomethingElseIsNotATimeout() async {
        do {
            _ = try await runner.run("/bin/sh", ["-c", "kill -SEGV $$"])
            Issue.record("debería haber fallado")
        } catch let CommandRunner.Failure.failed(_, status, _) {
            #expect(status == 11)
        } catch {
            Issue.record("falló de otra forma: \(error)")
        }
    }

    // Un programa que ignora SIGTERM se mata con SIGKILL un segundo después. Su hijo `sleep` sigue vivo y con las
    // tuberías abiertas, pero no se le espera: tarda 0,3 + 1 + hasta 1 s, no los 4 s del `sleep`
    @Test func aProgramThatIgnoresTerminateIsKilled() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CommandRunner.Failure.timedOut(command: "sh")) {
            try await CommandRunner(timeout: 0.3).run("/bin/sh", ["-c", "trap '' TERM; sleep 4"])
        }
        #expect(clock.now - start < .seconds(3))
    }

    @Test func aProgramThatTakesTooLongIsStopped() async {
        await #expect(throws: CommandRunner.Failure.timedOut(command: "sleep")) {
            try await runner.run("/bin/sleep", ["5"])
        }
    }
}

@MainActor
struct SystemMonitorTests {
    @Test func measuresRealValuesAndStopsPublishingWhenStopped() async throws {
        let monitor = SystemMonitor()
        monitor.start()
        // La CPU sale en la segunda medida (a los 0,6 s más lo que tarde `ps`, que con los tests en paralelo puede ser
        // mucho): se espera hasta 6 s
        var waited = 0
        while monitor.snapshot?.cpu == nil && waited < 60 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let snapshot = try #require(monitor.snapshot)
        #expect(snapshot.memory.usedBytes > 0 && snapshot.memory.usedBytes <= snapshot.memory.totalBytes)
        let cpu = try #require(snapshot.cpu)
        #expect((0...100).contains(cpu))
        #expect(!snapshot.processes.isEmpty && snapshot.processes.count <= 3)
        #expect(!snapshot.processes.contains { $0.name == "ps" })
        monitor.stop()
        #expect(monitor.snapshot == nil && !monitor.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(monitor.snapshot == nil)
    }

    // Parar justo después de arrancar: la medida que ya estaba pidiendo `ps` no se publica
    @Test func aMeasureThatFinishesAfterStopIsDropped() async throws {
        let monitor = SystemMonitor()
        monitor.start()
        monitor.stop()
        try await Task.sleep(for: .milliseconds(800))
        #expect(monitor.snapshot == nil)
    }
}
