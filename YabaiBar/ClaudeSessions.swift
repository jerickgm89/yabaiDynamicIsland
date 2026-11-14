import AppKit
import Foundation
import Observation
import os

// Lo que YabaiBar sabe de las sesiones de Claude Code: cuáles hay abiertas, leyendo `~/.claude/sessions`, y cuáles esperan
// tu respuesta, con los hooks. Los hooks llegan siempre (mandan el aviso aunque la isla esté cerrada); los archivos de
// sesión solo se leen con la pestaña Desarrollador a la vista o mientras alguna sesión espera, para limpiar lo que ya no
// vale (una sesión que se cerró).

/// Preguntas al sistema sobre un proceso
enum ProcessProbe {
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func info(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func parentPID(of pid: Int32) -> Int32? {
        info(of: pid).map { Int32($0.pbi_ppid) }
    }

    static func startDate(of pid: Int32) -> Date? {
        info(of: pid).map { Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec)) }
    }
}

extension ClaudeSessionRecord {
    /// El proceso vivo con ese pid es el que escribió el archivo, y no otro que heredó el pid: arrancaron con a lo sumo 2 s de
    /// diferencia (`procStart` tiene resolución de segundos). Sin hora en el archivo, solo cuenta que viva
    func isSameProcess(startedAt actual: Date?) -> Bool {
        guard let expected = startDate else { return true }
        guard let actual else { return false }
        return abs(expected.timeIntervalSince(actual)) <= 2
    }
}

/// Lee las sesiones abiertas de una carpeta de archivos `<pid>.json`. Nunca abre los `.key` que hay al lado: llevan un token
enum ClaudeSessionReader {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
    }

    /// Las sesiones cuyo proceso sigue vivo. Sin carpeta (nunca se usó Claude Code), ninguna; si no se puede leer, nil: no se
    /// sabe, y no hay que dar por cerradas las sesiones que se conocían
    static func read(
        in directory: URL, isAlive: (Int32) -> Bool = ProcessProbe.isAlive, startDate: (Int32) -> Date? = ProcessProbe.startDate
    ) -> [ClaudeSessionRecord]? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let records = files.filter { $0.pathExtension == "json" }.compactMap { url -> ClaudeSessionRecord? in
            guard let data = try? Data(contentsOf: url), let record = ClaudeSessionRecord.parse(data),
                  isAlive(record.pid), record.isSameProcess(startedAt: startDate(record.pid)) else { return nil }
            return record
        }
        return records.sorted { $0.pid < $1.pid }
    }
}

/// Si los hooks de YabaiBar están en el `settings.json` de Claude Code, y conectarlos o quitarlos desde Ajustes
@MainActor
@Observable
final class ClaudeConnection {
    /// nil hasta la primera comprobación
    private(set) var status: ClaudeHooksEditor.Status?
    private(set) var lastError: String?

    @ObservationIgnored private let file: ClaudeSettingsFile
    @ObservationIgnored private let confirm: @MainActor (_ title: String, _ message: String, _ action: String) -> Bool

    init(
        file: ClaudeSettingsFile,
        confirm: @escaping @MainActor (_ title: String, _ message: String, _ action: String) -> Bool = {
            DevConfirmation.confirm(title: $0, message: $1, action: $2, destructive: false)
        }
    ) {
        self.file = file
        self.confirm = confirm
    }

    /// El `yb` que va dentro de esta app
    static var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/yb").path
    }

    func refresh() {
        status = file.status()
    }

    /// Pregunta y, si el usuario confirma, añade los hooks. Devuelve si quedaron puestos
    @discardableResult
    func connect() -> Bool {
        lastError = nil
        guard FileManager.default.isExecutableFile(atPath: file.helperPath) else {
            lastError = "No se encuentra el ayudante «yb» dentro de la app."
            return false
        }
        let events = ClaudeHooksEditor.events.map(\.name.rawValue).joined(separator: ", ")
        // Si esta copia de la app no está en Aplicaciones (se corre desde una carpeta de compilación), los hooks apuntan a un
        // programa que desaparece al moverla o borrarla, y Claude Code daría un error de hook en cada herramienta
        let location = Self.isInstalled(file.helperPath)
            ? ""
            : "\n\nAtención: esta copia de YabaiBar no está en Aplicaciones. Los hooks apuntarán a \(file.helperPath) y dejarán de funcionar si la mueves o la borras."
        let allowed = confirm(
            "¿Conectar YabaiBar con Claude Code?",
            "Se añadirán cinco hooks a ~/.claude/settings.json (\(events)) para saber cuándo Claude te pregunta algo. "
                + "Mandan a YabaiBar el nombre del evento, el id y la carpeta de la sesión y, en una pregunta, lo que Claude Code "
                + "dice («necesita tu permiso para usar Bash»). Nunca lo que escribes ni lo que responde Claude.\n\n"
                + "Antes se guarda una copia como settings.json.bak-yabaibar (la primera vez). No se toca ninguna otra entrada, "
                + "pero el archivo se vuelve a escribir entero, con otro formato y las claves ordenadas. "
                + "Puedes quitarlos desde aquí cuando quieras." + location,
            "Conectar"
        )
        guard allowed else { return false }
        do {
            try file.connect()
            Logger.tools.info("Claude Code: hooks conectados")
        } catch {
            lastError = Self.message(for: error)
            Logger.tools.error("Claude Code: no se pudo conectar")
        }
        refresh()
        return status == .connected
    }

    /// Quita solo los hooks de YabaiBar. Pregunta antes
    @discardableResult
    func disconnect() -> Bool {
        lastError = nil
        let allowed = confirm(
            "¿Quitar los hooks de YabaiBar?",
            "Se quitarán de ~/.claude/settings.json solo las entradas que añadió YabaiBar. Dejará de avisarte cuando Claude te pregunte algo.",
            "Quitar"
        )
        guard allowed else { return false }
        do {
            try file.disconnect()
            Logger.tools.info("Claude Code: hooks quitados")
        } catch {
            lastError = Self.message(for: error)
            Logger.tools.error("Claude Code: no se pudieron quitar")
        }
        refresh()
        return status == .notConnected
    }

    /// La app está en /Applications o en ~/Applications
    static func isInstalled(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    private static func message(for error: Error) -> String {
        switch error as? ClaudeHooksEditor.Failure {
        case .unreadable: "settings.json no es un JSON válido: no se ha tocado."
        case .unexpectedShape: "La sección «hooks» de settings.json tiene una forma que no esperaba: no se ha tocado."
        case .cannotRead: "No se puede leer settings.json (¿permisos?): no se ha tocado."
        case .cannotWrite: "No se pudo guardar la copia de seguridad: no se ha tocado settings.json."
        case nil: "No se pudo escribir settings.json."
        }
    }
}

@MainActor
@Observable
final class ClaudeSessions {
    static let interval: Duration = .seconds(5)

    /// Las sesiones abiertas, con su estado. nil hasta la primera lectura, y con la pestaña cerrada
    private(set) var sessions: [ClaudeSession]?
    /// Cuántas esperan tu respuesta: lo que lee el punto naranja de la isla cerrada
    private(set) var waitingCount = 0
    let connection: ClaudeConnection

    /// Lo que se hizo un evento de los hooks: pregunta o terminó
    @ObservationIgnored var onOutcome: (@MainActor (ClaudeOutcome) -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let poller = Poller()
    @ObservationIgnored private var records: [ClaudeSessionRecord]?
    @ObservationIgnored private var states = ClaudeSessionStates()
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var loggedStatuses: Set<String> = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init(connection: ClaudeConnection, directory: URL = ClaudeSessionReader.defaultDirectory, now: @escaping () -> Date = { Date() }) {
        self.connection = connection
        self.directory = directory
        self.now = now
    }

    var isRunning: Bool { poller.isRunning }

    /// La pestaña Desarrollador se ve o deja de verse. Lo dice DevTools
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            connection.refresh()
            watch()
        } else {
            unwatch()
            sessions = nil
        }
        let wasRunning = poller.isRunning
        updatePolling()
        // Con una pregunta pendiente el sondeo ya corría con la isla cerrada: lo que ya se sabe se enseña al momento y se vuelve
        // a leer, en vez de esperar al siguiente turno
        if visible {
            publish()
            if wasRunning { refresh() }
        }
    }

    // MARK: - Avisos de los hooks

    func handle(_ message: AvisoMessage) {
        guard let event = message.claudeEvent else { return }
        let outcome = states.apply(event, at: now())
        waitingCount = states.waitingCount
        if let outcome {
            Logger.tools.info("Claude Code: \(event.name.rawValue, privacy: .public)")
            onOutcome?(outcome)
        }
        if isVisible {
            publish()
            // Una sesión que todavía no se ha leído: acaba de abrirse
            if records?.contains(where: { $0.sessionID == event.sessionID }) != true { refresh() }
        }
        updatePolling()
    }

    // MARK: - Lectura de los archivos

    private func updatePolling() {
        let needed = isVisible || waitingCount > 0
        if needed, !poller.isRunning {
            poller.start(interval: Self.interval) { [weak self] generation in await self?.read(generation: generation) }
        } else if !needed, poller.isRunning {
            poller.stop()
        }
    }

    /// Lee ahora, sin esperar a la siguiente: al cambiar la carpeta
    func refresh() {
        guard poller.isRunning else { return }
        let generation = poller.generation
        Task { await read(generation: generation) }
    }

    private func read(generation: Int) async {
        let directory = directory
        let found = await Task.detached { ClaudeSessionReader.read(in: directory) }.value
        // Si mientras tanto se paró o se volvió a arrancar, esta lectura ya no vale
        guard poller.isCurrent(generation) else { return }
        if let found {
            records = found
            logNewStatuses(in: found)
        }
        states.prune(records: found, at: now())
        waitingCount = states.waitingCount
        publish()
        updatePolling()
    }

    // Un `status` que no se conoce se anota una vez, para saber qué escribe Claude Code además de busy e idle (el valor, sin más)
    private func logNewStatuses(in found: [ClaudeSessionRecord]) {
        for status in Set(found.map(\.status)).subtracting(ClaudeSessionRecord.knownStatuses).subtracting(loggedStatuses) {
            loggedStatuses.insert(status)
            Logger.tools.info("Claude Code: estado de sesión nuevo «\(ClaudeHookText.clean(status, limit: 20), privacy: .public)»")
        }
    }

    private func publish() {
        guard isVisible, let records else { return }
        sessions = states.sessions(from: records)
    }

    #if DEBUG
    /// Para el snapshot de la isla: una lectura sin dejar nada en marcha
    func sampleOnce() async {
        guard !poller.isRunning else { return }
        let directory = directory
        if let found = await Task.detached(operation: { ClaudeSessionReader.read(in: directory) }).value {
            records = found
            sessions = states.sessions(from: found)
        }
    }

    /// Para probar sin tener sesiones de verdad
    func inject(records: [ClaudeSessionRecord], states: ClaudeSessionStates = ClaudeSessionStates()) {
        self.records = records
        self.states = states
        waitingCount = states.waitingCount
        sessions = states.sessions(from: records)
    }

    /// Tres sesiones inventadas, una de ellas con una pregunta, para el snapshot
    func injectDemo() {
        func record(_ pid: Int32, _ folder: String, _ name: String, _ status: String, _ entrypoint: String) -> ClaudeSessionRecord {
            ClaudeSessionRecord(
                pid: pid, sessionID: "demo-\(pid)", cwd: "/demo/\(folder)", name: name, status: status, entrypoint: entrypoint,
                procStart: "", statusUpdatedAt: nil
            )
        }
        var demo = ClaudeSessionStates()
        _ = demo.apply(
            ClaudeHookEvent(name: .notification, sessionID: "demo-1", cwd: "/demo/tienda", kind: "permission_prompt"), at: now()
        )
        inject(
            records: [
                record(1, "tienda", "Arreglar el carrito", "busy", ClaudeOrigin.desktopEntrypoint),
                record(2, "api", "Migración", "busy", "cli"), record(3, "docs", "", "idle", "cli"),
            ],
            states: demo
        )
    }

    /// Quita lo inyectado: el snapshot no deja un punto naranja inventado en la isla
    func resetInjected() {
        records = nil
        states = ClaudeSessionStates()
        waitingCount = 0
        sessions = nil
    }
    #endif

    // La carpeta cambia cuando una sesión se abre o se cierra: se lee al momento, sin esperar a los 5 s. Los cambios dentro
    // de un archivo (el estado) no avisan: de eso se encarga la lectura periódica
    private func watch() {
        guard watcher == nil else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func unwatch() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Ir a la sesión

    /// Lleva a primer plano la app de la sesión: la de Claude o la terminal o el editor en que corre. Devuelve si encontró
    /// alguna
    @discardableResult
    func activate(sessionID: String) -> Bool {
        guard let record = records?.first(where: { $0.sessionID == sessionID }),
              let app = Self.originApp(of: record), let url = app.bundleURL else {
            Logger.tools.info("Claude Code: no se encontró la app de esa sesión")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    /// La primera app normal de la que cuelga el proceso de la sesión. Para las de la app de Claude, esa misma app aunque
    /// no se encuentre el camino
    static func originApp(of record: ClaudeSessionRecord) -> NSRunningApplication? {
        let pid = ProcessAncestry.firstApp(
            from: record.pid, parent: ProcessProbe.parentPID(of:),
            isApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
        )
        if let pid, let app = NSRunningApplication(processIdentifier: pid) { return app }
        guard record.origin == .desktopApp else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeOrigin.desktopBundleID).first
    }
}
