import Darwin
import Foundation
import Observation
import os

// Lo que se lee del sistema para el módulo Sistema: los contadores de la CPU y la memoria con Mach, y la presión de
// memoria con sysctl. Son llamadas rápidas y no piden permisos.
enum SystemReader {
    // Una sola vez: cada llamada a mach_host_self() suma una referencia al puerto
    private static let host = mach_host_self()

    /// Los contadores de la CPU de todos los núcleos juntos (`HOST_CPU_LOAD_INFO`)
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        // En el orden de CPU_STATE_USER, SYSTEM, IDLE y NICE
        let ticks = info.cpu_ticks
        return CPUTicks(user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }

    /// La memoria usada como la cuenta el Monitor de Actividad: la de las apps (interna menos la purgable), la fija y la
    /// comprimida
    static func memory() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let apps = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let pages = apps + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return MemoryStats(
            usedBytes: pages * UInt64(getpagesize()), totalBytes: ProcessInfo.processInfo.physicalMemory,
            pressure: pressure()
        )
    }

    private static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(sysctlLevel: Int(level))
    }
}

// El módulo Sistema de la pestaña Desarrollador: la CPU, la memoria y los tres procesos que más CPU usan, cada 2 s y
// solo mientras la pestaña está a la vista (DevTools lo arranca y lo para). La CPU es la diferencia entre dos lecturas:
// cada arranque empieza con una lectura base nueva, porque una vieja daría la media de todo el tiempo que estuvo cerrada.
@MainActor
@Observable
final class SystemMonitor {
    static let interval: Duration = .seconds(2)
    /// Hasta la segunda lectura de la CPU: tiene que pasar un poco de tiempo para que haya diferencia que medir
    static let firstDelay: Duration = .milliseconds(600)

    private(set) var snapshot: SystemSnapshot?

    @ObservationIgnored private let runner: CommandRunner
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var baseline: CPUTicks?
    /// Cada arranque y cada parada lo suben: una medida que se pidió antes de que cambiara ya no se publica, como en
    /// SpacesStore. Cancelar la tarea no basta: `ps` tarda y la pestaña pudo cerrarse y abrirse mientras tanto
    @ObservationIgnored private var generation = 0

    init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        generation += 1
        let generation = generation
        baseline = SystemReader.cpuTicks()
        Logger.tools.info("Monitor del sistema: en marcha")
        task = Task { [weak self] in
            // La memoria y los procesos no necesitan diferencia: se miden ya. La CPU no: la lectura base se acaba de
            // tomar y entre las dos pasan microsegundos, así que saldría ruido. Se mide a los 0,6 s
            await self?.sample(generation: generation, measuresCPU: false)
            var delay = Self.firstDelay
            while !Task.isCancelled {
                // Con tolerancia: sin ella, macOS retrasa las esperas largas (ajuste 21)
                try? await Task.sleep(for: delay, tolerance: .milliseconds(200))
                // Si el monitor ya no existe, el bucle se acaba en vez de seguir despertando cada 2 s
                guard !Task.isCancelled, let monitor = self else { return }
                await monitor.sample(generation: generation)
                delay = Self.interval
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        generation += 1
        task?.cancel()
        task = nil
        baseline = nil
        snapshot = nil
        Logger.tools.info("Monitor del sistema: parado")
    }

    private func sample(generation: Int, measuresCPU: Bool = true) async {
        // Una tarea cancelada (parar y volver a arrancar) sigue ejecutando su cuerpo hasta el primer await: que no
        // lance un `ps` inútil ni pise la lectura base de la sesión nueva
        guard generation == self.generation, !Task.isCancelled else { return }
        var cpu: Double?
        if measuresCPU {
            let ticks = SystemReader.cpuTicks()
            cpu = baseline.flatMap { old in ticks.flatMap { CPUTicks.usage(from: old, to: $0) } }
            if let ticks { baseline = ticks }
        }
        let memory = SystemReader.memory()
        let output: String?
        do {
            output = try await runner.run("/bin/ps", ["-Ao", "pid,pcpu,rss,comm", "-r"])
        } catch {
            // Sin nombres de proceso: solo el tipo de fallo
            Logger.tools.info("Monitor del sistema: ps falló (\(String(describing: error), privacy: .public))")
            output = nil
        }
        // Si mientras tanto se paró o se volvió a arrancar, esta medida ya no vale
        guard generation == self.generation, let memory else { return }
        snapshot = SystemSnapshot(
            cpu: cpu ?? snapshot?.cpu,
            memory: memory,
            processes: output.map { PsParser.parse($0) } ?? snapshot?.processes ?? []
        )
    }

    #if DEBUG
    /// Para el snapshot de la isla: una medida completa (con dos lecturas de la CPU) sin dejar el monitor en marcha
    func sampleOnce() async {
        guard task == nil else { return }
        generation += 1
        let generation = generation
        baseline = SystemReader.cpuTicks()
        try? await Task.sleep(for: .milliseconds(400))
        await sample(generation: generation)
        // Si mientras tanto arrancó el monitor de verdad, la lectura base es suya
        if task == nil { baseline = nil }
    }
    #endif
}
