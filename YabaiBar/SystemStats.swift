import Foundation

// Lógica pura del monitor del sistema: de los contadores de la CPU y de la memoria, y de la salida de `ps`, a lo que
// enseña el módulo Sistema. Lo que habla con el sistema está en SystemMonitor.swift.

/// Los contadores de la CPU, sumados los de todos los núcleos, en un momento. Solo valen por la diferencia entre dos
struct CPUTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var busy: UInt64 { user + system + nice }
    var total: UInt64 { busy + idle }

    /// El porcentaje de la CPU en uso entre dos lecturas, de 0 a 100. nil si no pasó tiempo o los contadores
    /// retrocedieron, como tras reiniciar el contador
    static func usage(from old: CPUTicks, to new: CPUTicks) -> Double? {
        guard new.total > old.total, new.busy >= old.busy else { return nil }
        let busy = Double(new.busy - old.busy)
        let total = Double(new.total - old.total)
        return min(100, max(0, busy / total * 100))
    }
}

/// La presión de memoria que da macOS (`kern.memorystatus_vm_pressure_level`)
enum MemoryPressure: Equatable, Sendable {
    case normal, warning, critical

    init(sysctlLevel level: Int) {
        switch level {
        case 2: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }
}

struct MemoryStats: Equatable, Sendable {
    /// Lo que cuenta como «Memoria usada» en el Monitor de Actividad: app + fija + comprimida
    var usedBytes: UInt64
    var totalBytes: UInt64
    var pressure: MemoryPressure

    /// De 0 a 1
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

struct ProcessUsage: Equatable, Sendable, Identifiable {
    var pid: Int32
    var name: String
    /// Por núcleo: un proceso puede pasar del 100
    var cpu: Double
    var rssBytes: UInt64

    var id: Int32 { pid }
}

/// Lo que enseña el módulo Sistema
struct SystemSnapshot: Equatable, Sendable {
    /// nil hasta la segunda lectura, que es cuando hay diferencia que medir
    var cpu: Double?
    var memory: MemoryStats
    var processes: [ProcessUsage]
}

// La salida de `ps -Ao pid,pcpu,rss,comm -r`: una línea de cabecera y, ordenados por CPU, el pid, el %CPU, la memoria
// residente en KB y la ruta del ejecutable, que puede llevar espacios y por eso es lo último
enum PsParser {
    /// Los procesos que más CPU usan, sin el propio `ps`. Las líneas que no se entienden se saltan
    static func parse(_ output: String, limit: Int = 3, excluding excluded: Set<String> = ["ps"]) -> [ProcessUsage] {
        var processes: [ProcessUsage] = []
        for line in output.split(whereSeparator: \.isNewline) {
            // Solo los tres primeros campos se separan: lo que sigue es la ruta tal cual, con sus espacios
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let rss = UInt64(fields[2]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")), cpu.isFinite else { continue }
            // Con una cifra absurda en KB, multiplicar por 1024 se desbordaría: la línea se salta, como las malas
            let (bytes, overflow) = rss.multipliedReportingOverflow(by: 1024)
            let name = processName(String(fields[3]))
            guard !overflow, !name.isEmpty, !excluded.contains(name) else { continue }
            processes.append(ProcessUsage(pid: pid, name: name, cpu: cpu, rssBytes: bytes))
            if processes.count == limit { break }
        }
        return processes
    }

    /// «/Applications/Claude.app/Contents/MacOS/Claude» → «Claude». Sin ruta (`kernel_task`), tal cual
    static func processName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

// Cómo se escriben las cifras: en español, con la coma decimal
enum SystemFormat {
    /// «11,2» o «16»: los gigabytes con un decimal, sin él si son enteros
    static func gigabytes(_ bytes: UInt64) -> String {
        let value = (Double(bytes) / 1_073_741_824 * 10).rounded() / 10
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return text.replacingOccurrences(of: ".", with: ",")
    }

    /// «11,2 / 32 GB»
    static func memory(_ stats: MemoryStats) -> String {
        "\(gigabytes(stats.usedBytes)) / \(gigabytes(stats.totalBytes)) GB"
    }

    /// «23 %»
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(value.rounded())) %"
    }
}
