import Foundation

// Lógica pura del módulo Puertos: de la salida de `lsof` a los puertos que escuchan y a las filas del módulo.

/// Un proceso escuchando en un puerto TCP
struct PortListener: Equatable, Sendable, Identifiable {
    var pid: Int32
    var command: String
    var uid: UInt32
    var port: Int

    /// Un proceso puede escuchar en varios puertos: la pareja es lo que identifica la fila
    var id: String { "\(pid):\(port)" }
    var url: URL? { URL(string: "http://localhost:\(port)") }
}

// La salida de `lsof +c 0 -nP -iTCP -sTCP:LISTEN -F pcnuL`: una línea por campo, con su letra delante. `p` abre un
// proceso (su pid), `c` es su nombre (entero con `+c 0`; sin él lsof lo corta a 9 letras), `u` su usuario, `L` su nombre
// de usuario, y cada `f` abre un descriptor de archivo, con su `n`: `*:7000`, `127.0.0.1:7265` o `[::1]:8080`.
enum LsofParser {
    /// Los puertos que escuchan, sin repetir (un servidor en IPv4 y en IPv6 sale dos veces) y por orden de puerto
    static func parse(_ output: String) -> [PortListener] {
        var listeners: [PortListener] = []
        var seen: Set<String> = []
        var pid: Int32?
        var command = ""
        var uid: UInt32 = 0
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                pid = Int32(value)
                command = ""
                uid = 0
            case "c": command = String(value)
            case "u": uid = UInt32(value) ?? 0
            case "n":
                guard let pid, let port = port(in: String(value)) else { continue }
                let listener = PortListener(pid: pid, command: command, uid: uid, port: port)
                if seen.insert(listener.id).inserted { listeners.append(listener) }
            default: break
            }
        }
        return listeners.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// «*:7000» → 7000, «[::1]:8080» → 8080. nil si no acaba en un puerto
    static func port(in name: String) -> Int? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        return Int(name[name.index(after: colon)...])
    }
}

// Los procesos que escuchan sin ser un servidor de desarrollo, y los que no se deben cerrar desde aquí
enum SystemServices {
    /// Servicios de macOS que abren puertos (AirPlay en el 5000 y el 7000, el compañero de Continuidad…): no son lo que
    /// se busca y cerrarlos no tiene sentido
    static let hidden: Set<String> = [
        "controlcenter", "rapportd", "sharingd", "wifiagent", "airportd", "identityservicesd", "usereventagent",
        "launchd", "mdnsresponder", "netbiosd", "remoted", "screensharingd", "remotepairingdeviced", "apsd",
        "assistantd", "lockdownd", "cupsd", "sshd", "smbd",
    ]

    /// Se ven, pero sin botón de cerrar: parar el servidor de Docker Desktop se llevaría por delante los contenedores, y
    /// la propia isla no se cierra a sí misma
    static let protected: Set<String> = ["com.docker.backend", "docker", "docker-proxy", "vpnkit", "yabaibar"]
    static let dockerBackend = "com.docker.backend"

    static func isHidden(_ command: String) -> Bool { hidden.contains(command.lowercased()) }
    static func isProtected(_ command: String) -> Bool { protected.contains(command.lowercased()) }
}

enum PortRows {
    /// Cuántas filas caben; el resto solo cuenta en la cabecera
    static let visibleRows = ModuleRowLayout.maxRows

    /// Solo se cierran procesos del mismo usuario, nunca YabaiBar ni el pid 1, y nunca los protegidos. Lo mira la fila
    /// (para no ofrecer el botón) y DevTools (por si se pide igualmente)
    static func canClose(_ listener: PortListener, ownUID: UInt32, ownPID: Int32) -> Bool {
        listener.uid == ownUID && listener.pid != ownPID && listener.pid > 1 && !SystemServices.isProtected(listener.command)
            && !SystemServices.isHidden(listener.command)
    }

    /// `ownUID` y `ownPID` son los de YabaiBar.
    /// `hidingDockerBackend`: los puertos que abre Docker Desktop son los de sus contenedores, y con el módulo Docker a
    /// la vista salen allí; sin él, aquí
    static func content(
        of listeners: [PortListener]?, ownUID: UInt32, ownPID: Int32, hidingDockerBackend: Bool = false
    ) -> ModuleRowsContent {
        guard let listeners else { return ModuleRowsContent(summary: "", rows: [], notice: nil) }
        let shown = listeners.filter {
            !SystemServices.isHidden($0.command) && !(hidingDockerBackend && $0.command == SystemServices.dockerBackend)
        }
        guard !shown.isEmpty else {
            return ModuleRowsContent(
                summary: "",
                rows: [],
                notice: .init(title: "Ningún puerto abierto", subtitle: "Aquí salen los servidores locales.")
            )
        }
        let rows = shown.prefix(visibleRows).map { listener -> ModuleRow in
            let mine = listener.uid == ownUID
            return ModuleRow(
                id: listener.id, leading: .code(":\(listener.port)"), title: listener.command,
                detail: mine ? "" : "de otro usuario",
                actions: canClose(listener, ownUID: ownUID, ownPID: ownPID) ? [.open, .copy, .close] : [.open, .copy],
                isDimmed: !mine
            )
        }
        let summary = shown.count > visibleRows ? "\(visibleRows) de \(shown.count)" : "\(shown.count) abiertos"
        return ModuleRowsContent(summary: summary, rows: Array(rows), notice: nil)
    }
}
