import Foundation

// Lógica pura del módulo Docker: de la salida de `docker ps -a --format '{{json .}}'` a los contenedores, y de estos a
// las filas del módulo, con los proyectos de Compose agrupados.

struct DockerContainer: Equatable, Sendable, Identifiable {
    /// El identificador corto que da `docker ps`
    var id: String
    var name: String
    var image: String
    /// `running`, `exited`, `paused`, `restarting`, `created`, `dead`
    var state: String
    /// «Up 2 hours», «Exited (0) 3 hours ago»
    var status: String
    /// «0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp»
    var ports: String
    /// El proyecto de Compose del que viene, si viene de uno
    var project: String?

    /// Corre o está a punto: `restarting` y `paused` también se paran y reinician desde aquí
    var isAlive: Bool { ["running", "restarting", "paused"].contains(state) }
}

/// Lo que se sabe de Docker en una medida
enum DockerState: Equatable, Sendable {
    case notInstalled
    /// El programa está, pero el demonio no contesta: Docker Desktop cerrado
    case notRunning
    case containers([DockerContainer])
}

enum DockerParser {
    private struct Raw: Decodable {
        let ID: String
        let Names: String
        let Image: String
        let State: String
        let Status: String
        let Ports: String
        let Labels: String
    }

    static let composeProjectLabel = "com.docker.compose.project"

    /// Una línea de JSON por contenedor. Las que no se entienden se saltan, también las vacías
    static func parse(_ output: String) -> [DockerContainer] {
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let raw = try? decoder.decode(Raw.self, from: Data(line.utf8)) else { return nil }
            // Un contenedor puede tener varios nombres, separados por comas; el primero es el suyo
            let name = raw.Names.split(separator: ",").first.map(String.init) ?? raw.ID
            return DockerContainer(
                id: raw.ID, name: name.hasPrefix("/") ? String(name.dropFirst()) : name, image: raw.Image,
                state: raw.State, status: raw.Status, ports: raw.Ports, project: project(in: raw.Labels)
            )
        }
    }

    /// El valor de `com.docker.compose.project` en «clave=valor,clave=valor»
    static func project(in labels: String) -> String? {
        let prefix = composeProjectLabel + "="
        guard let label = labels.split(separator: ",").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = label.dropFirst(prefix.count)
        return value.isEmpty ? nil : String(value)
    }
}

enum DockerStatus {
    /// Los puertos del Mac que el contenedor publica, sin repetir y en orden: «0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp»
    /// da [5432]. Un puerto que solo se expone («5432/tcp») no es accesible desde fuera y no cuenta
    static func hostPorts(_ ports: String) -> [Int] {
        var result: [Int] = []
        for entry in ports.components(separatedBy: ", ") {
            guard let arrow = entry.range(of: "->"), let colon = entry[..<arrow.lowerBound].lastIndex(of: ":"),
                  let port = Int(entry[entry.index(after: colon)..<arrow.lowerBound]), !result.contains(port) else { continue }
            result.append(port)
        }
        return result
    }

    /// Cuánto lleva en marcha, abreviado: «Up 2 hours» → «2 h», «Up About an hour (healthy)» → «1 h». nil si no está en
    /// marcha o no se entiende
    static func uptime(_ status: String) -> String? {
        guard status.hasPrefix("Up ") else { return nil }
        var text = String(status.dropFirst(3))
        if let paren = text.range(of: " (") { text = String(text[..<paren.lowerBound]) }
        switch text {
        case "Less than a second": return "<1 s"
        case "About a minute": return "1 min"
        case "About an hour": return "1 h"
        default: break
        }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let amount = Int(parts[0]) else { return nil }
        let unit: String
        switch parts[1] {
        case "second", "seconds": unit = "s"
        case "minute", "minutes": unit = "min"
        case "hour", "hours": unit = "h"
        case "day", "days": unit = "d"
        case "week", "weeks": unit = "sem"
        case "month", "months": unit = "meses"
        case "year", "years": unit = "años"
        default: return nil
        }
        return "\(amount) \(unit)"
    }
}

enum DockerRows {
    static let stoppedToggleID = "docker:stopped"
    static let backID = "docker:running"
    static let noneID = "docker:none"

    /// A qué se refiere una fila: un contenedor («container:3f1c2a9b7d10») o un proyecto de Compose («project:shop»)
    static func target(ofRow id: String) -> (container: String?, project: String?) {
        if id.hasPrefix("container:") { return (String(id.dropFirst("container:".count)), nil) }
        if id.hasPrefix("project:") { return (nil, String(id.dropFirst("project:".count))) }
        return (nil, nil)
    }

    /// `showStopped`: el módulo enseña los parados (con su botón de iniciar) en vez de los que corren
    static func content(of state: DockerState?, showStopped: Bool) -> ModuleRowsContent {
        switch state {
        case nil:
            return ModuleRowsContent(summary: "", rows: [], notice: nil)
        case .notInstalled:
            return ModuleRowsContent(
                summary: "", rows: [],
                notice: .init(title: "Docker no está instalado", subtitle: "Instala Docker Desktop para verlo aquí.")
            )
        case .notRunning:
            return ModuleRowsContent(
                summary: "", rows: [],
                notice: .init(title: "Docker no está en marcha", subtitle: "Abre Docker Desktop para ver los contenedores.")
            )
        case .containers(let containers):
            let alive = containers.filter(\.isAlive)
            let stopped = containers.filter { !$0.isAlive }
            if containers.isEmpty {
                return ModuleRowsContent(
                    summary: "", rows: [], notice: .init(title: "Sin contenedores", subtitle: "Aquí salen los que crees.")
                )
            }
            if showStopped, !stopped.isEmpty { return stoppedContent(stopped) }
            return aliveContent(alive, stoppedCount: stopped.count)
        }
    }

    // Los que corren, con los proyectos de Compose de dos o más agrupados en una sola fila. Con parados, la última fila
    // es «+n parados»
    private static func aliveContent(_ alive: [DockerContainer], stoppedCount: Int) -> ModuleRowsContent {
        let capacity = stoppedCount > 0 ? ModuleRowLayout.maxRows - 1 : ModuleRowLayout.maxRows
        var rows = groupedRows(alive)
        if rows.isEmpty {
            rows = [ModuleRow(id: noneID, title: "Ninguno en marcha", isDimmed: true)]
        }
        rows = Array(rows.prefix(capacity))
        if stoppedCount > 0 {
            rows.append(
                ModuleRow(
                    id: stoppedToggleID, title: "+\(stoppedCount) parados", actions: [.showStopped], isDimmed: true,
                    showsActionsAlways: true
                )
            )
        }
        return ModuleRowsContent(summary: "\(alive.count) en marcha", rows: rows, notice: nil)
    }

    private static func groupedRows(_ alive: [DockerContainer]) -> [ModuleRow] {
        let byProject = Dictionary(grouping: alive.compactMap { container in container.project.map { ($0, container) } }) {
            $0.0
        }
        var rows: [ModuleRow] = []
        for (project, members) in byProject where members.count > 1 {
            rows.append(
                ModuleRow(
                    id: "project:\(project)", leading: .status(isOn: true), title: project,
                    detail: "\(members.count) contenedores", actions: [.restart, .stop]
                )
            )
        }
        for container in alive where container.project.flatMap({ byProject[$0]?.count }).map({ $0 < 2 }) ?? true {
            let ports = DockerStatus.hostPorts(container.ports).prefix(2).map { ":\($0)" }.joined(separator: " ")
            let detail = [ports, DockerStatus.uptime(container.status) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            rows.append(
                ModuleRow(
                    id: "container:\(container.id)", leading: .status(isOn: true), title: container.name, detail: detail,
                    actions: [.restart, .stop]
                )
            )
        }
        return rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // Los parados, con iniciar, y una última fila para volver a los que corren
    private static func stoppedContent(_ stopped: [DockerContainer]) -> ModuleRowsContent {
        var rows = stopped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(ModuleRowLayout.maxRows - 1)
            .map { container in
                ModuleRow(
                    id: "container:\(container.id)", leading: .status(isOn: false), title: container.name,
                    detail: container.image, actions: [.start], isDimmed: true
                )
            }
        rows.append(
            ModuleRow(id: backID, title: "Volver a los que corren", actions: [.hideStopped], isDimmed: true, showsActionsAlways: true)
        )
        return ModuleRowsContent(summary: "\(stopped.count) parados", rows: rows, notice: nil)
    }
}
