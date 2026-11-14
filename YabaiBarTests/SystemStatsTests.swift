import Foundation
import Testing
@testable import YabaiBar

struct CPUTicksTests {
    private func ticks(_ user: UInt64, _ system: UInt64, _ idle: UInt64, _ nice: UInt64 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    // De la primera lectura (150 ocupados de 1000) a la segunda (230 de 1300): 80 de los 300 ticks que pasaron
    @Test func usageIsTheBusyShareOfTheTicksBetweenTwoReadings() throws {
        let usage = try #require(CPUTicks.usage(from: ticks(100, 50, 850), to: ticks(150, 80, 1070)))
        #expect(abs(usage - 80.0 / 300 * 100) < 0.0001)
    }

    // El tiempo `nice` (procesos de baja prioridad) también es CPU ocupada: 50 de 100
    @Test func niceTimeCountsAsBusy() throws {
        let usage = try #require(CPUTicks.usage(from: ticks(0, 0, 100), to: ticks(0, 0, 150, 50)))
        #expect(usage == 50)
    }

    @Test func anIdleMachineIsAtZeroAndABusyOneAtOneHundred() throws {
        #expect(try #require(CPUTicks.usage(from: ticks(10, 10, 100), to: ticks(10, 10, 200))) == 0)
        #expect(try #require(CPUTicks.usage(from: ticks(10, 10, 100), to: ticks(60, 60, 100))) == 100)
    }

    // Sin tiempo entre las lecturas no hay nada que medir, ni si los contadores retroceden
    @Test func noElapsedTimeOrGoingBackwardsGivesNothing() {
        #expect(CPUTicks.usage(from: ticks(10, 10, 100), to: ticks(10, 10, 100)) == nil)
        #expect(CPUTicks.usage(from: ticks(10, 10, 100), to: ticks(5, 5, 50)) == nil)
        // Más total pero menos ocupado: un contador que se reinició
        #expect(CPUTicks.usage(from: ticks(100, 100, 100), to: ticks(10, 10, 500)) == nil)
    }
}

struct MemoryStatsTests {
    @Test(arguments: [(1, MemoryPressure.normal), (2, .warning), (4, .critical), (0, .normal), (3, .normal)])
    func pressureFollowsTheSysctlLevel(level: Int, pressure: MemoryPressure) {
        #expect(MemoryPressure(sysctlLevel: level) == pressure)
    }

    @Test func usedFractionStaysBetweenZeroAndOne() {
        let gigabyte: UInt64 = 1_073_741_824
        #expect(MemoryStats(usedBytes: 8 * gigabyte, totalBytes: 32 * gigabyte, pressure: .normal).usedFraction == 0.25)
        #expect(MemoryStats(usedBytes: 40 * gigabyte, totalBytes: 32 * gigabyte, pressure: .normal).usedFraction == 1)
        #expect(MemoryStats(usedBytes: gigabyte, totalBytes: 0, pressure: .normal).usedFraction == 0)
    }

    // 12 025 908 428 bytes son 11,2 GiB, con coma decimal; los enteros, sin decimal
    @Test func gigabytesUseASpanishDecimalComma() {
        #expect(SystemFormat.gigabytes(12_025_908_428) == "11,2")
        #expect(SystemFormat.gigabytes(34_359_738_368) == "32")
        #expect(SystemFormat.gigabytes(1_610_612_736) == "1,5")
        #expect(SystemFormat.gigabytes(0) == "0")
        // 10,96 se redondea a 11, y entonces no lleva decimal
        #expect(SystemFormat.gigabytes(11_769_113_641) == "11")
    }

    @Test func memoryAndPercentAreWrittenForTheModule() {
        let stats = MemoryStats(usedBytes: 12_025_908_428, totalBytes: 34_359_738_368, pressure: .normal)
        #expect(SystemFormat.memory(stats) == "11,2 / 32 GB")
        #expect(SystemFormat.percent(23.4) == "23 %")
        #expect(SystemFormat.percent(0.4) == "0 %")
        #expect(SystemFormat.percent(100) == "100 %")
    }
}

// ps-top.txt es la salida real de `ps -Ao pid,pcpu,rss,comm -r` de esta máquina (con el nombre de usuario cambiado):
// una cabecera y once procesos, con rutas con espacios y una sin barra inicial
struct PsParserTests {
    private func parse(_ text: String, limit: Int = 3) -> [ProcessUsage] {
        PsParser.parse(text, limit: limit)
    }

    @Test func takesTheTopThreeByTheOrderPsGives() throws {
        let top = parse(try Fixture.text("ps-top"))
        #expect(top.map(\.name) == ["claude", "com.apple.WebKit.WebContent", "WindowServer"])
        #expect(top.map(\.pid) == [12341, 12890, 171])
        #expect(top.map(\.cpu) == [23.4, 16.1, 14.9])
        // La memoria residente sale en KB
        let kilobytes: [UInt64] = [672_912, 2_356_464, 631_808]
        #expect(top.map(\.rssBytes) == kilobytes.map { $0 * 1024 })
    }

    @Test func readsEveryProcessAndSkipsTheHeader() throws {
        let all = parse(try Fixture.text("ps-top"), limit: 50)
        #expect(all.count == 11)
        #expect(all.first?.pid == 12341)
    }

    // «Claude Helper (Renderer)» lleva espacios y paréntesis; la última línea no empieza por «/»
    @Test func namesWithSpacesAndRelativePathsKeepTheirLastComponent() throws {
        let all = parse(try Fixture.text("ps-top"), limit: 50)
        #expect(all.contains { $0.name == "Claude Helper (Renderer)" })
        #expect(all.contains { $0.name == "openlogi-agent" })
        #expect(all.contains { $0.name == "launchd" })
    }

    @Test func psItselfIsLeftOut() {
        let output = "  PID  %CPU    RSS COMM\n  999  99.0   1000 /bin/ps\n   12   5.0   2048 /usr/sbin/coreaudiod\n"
        #expect(parse(output).map(\.name) == ["coreaudiod"])
    }

    // Con otro idioma ps escribiría 12,5; y por núcleo pasa del 100: no se recorta
    @Test func acceptsCommaDecimalsAndMoreThanOneHundredPercent() {
        let output = "   10  12,5   2048 /usr/sbin/a\n   11 345.6   1024 /usr/sbin/b\n"
        #expect(parse(output).map(\.cpu) == [12.5, 345.6])
    }

    // Double("nan") y Double("inf") se leen, y un rss enorme desbordaría al pasar a bytes: son líneas malas
    @Test func nonFiniteNumbersAndOverflowingMemoryAreSkipped() {
        let output = "  1  nan  100 /a/uno\n  2  inf  100 /a/dos\n  3  1.0  18446744073709551615 /a/tres\n  4  2.0  100 /a/cuatro\n"
        #expect(parse(output).map(\.name) == ["cuatro"])
        #expect(SystemFormat.percent(.nan) == "—")
    }

    @Test func badLinesAreSkipped() {
        let output = "garbage\n1 2\nx 1.0 5 /a\n  7  1.0  nope /b\n\n   8   2.0   100 /usr/bin/ok\n"
        #expect(parse(output).map(\.name) == ["ok"])
        #expect(parse("").isEmpty)
    }

    @Test func aCommandWithoutPathKeepsItsName() {
        #expect(PsParser.processName("kernel_task") == "kernel_task")
        #expect(PsParser.processName("/sbin/launchd") == "launchd")
        #expect(PsParser.processName("  /usr/sbin/cfprefsd ") == "cfprefsd")
    }
}
