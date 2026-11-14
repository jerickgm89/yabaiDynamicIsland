import Foundation
import Observation
import os

/// Dónde están `git` y `gh`. Una app abierta desde el Finder no hereda el PATH de la shell: rutas conocidas. `/usr/bin/git` no
/// vale: sin las herramientas de línea de comandos es un atajo que abre el instalador
enum GitTools {
    static let gitPaths = [
        "/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]
    static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    static func git() -> String? { gitPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static func gh() -> String? { ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }
}

// El módulo Git: el estado de los repositorios que se vigilan y los avisos de la isla cerrada. Solo informa: nunca hace commit,
// push, fetch ni crea etiquetas.
//
// Qué repositorios: los de las sesiones de Claude Code abiertas (la carpeta de cada una, y de ahí su repositorio) y las
// carpetas de Ajustes. Funciona con la isla cerrada, pero solo por eventos: FSEvents avisa de que algo cambió en un repositorio
// (con 5 s de latencia) y se vuelve a medir, como mucho una vez cada 30 s por repositorio. `~/.claude/sessions` se vigila con un
// `DispatchSource`. Con la pestaña Desarrollador a la vista, además, `gh` se consulta cada minuto.
//
// Todas las llamadas a git llevan `--no-optional-locks` (sin él, `git status` reescribe `.git/index`, eso dispara FSEvents y se
// vuelve a medir sin fin, y además choca con los git del usuario) y `core.fsmonitor=false` (una configuración del repositorio
// podría ejecutar un programa). La carpeta se pasa con `-C` y el repositorio de GitHub con `-R`: `CommandRunner` no cambia
// de directorio. Un fallo de `gh` es «no se sabe»: nunca se avisa de «sin release» ni de un CI que falló por eso.
@MainActor
@Observable
final class GitMonitor {
    static let refreshGap: TimeInterval = 30
    static let fileLatency: TimeInterval = 5
    static let githubInterval: Duration = .seconds(60)
    static let githubFreshness: TimeInterval = 50
    static let ciInterval: Duration = .seconds(30)
    /// El CI se sigue hasta media hora tras un push
    static let ciLimit: TimeInterval = 30 * 60
    /// Si pasados 3 min ningún flujo de trabajo empezó para ese commit, no hay CI que esperar
    static let ciNoRunLimit: TimeInterval = 3 * 60
    static let sessionsDebounce: Duration = .seconds(3)
    static let maxRepos = 12
    /// Una carpeta que no era un repositorio se vuelve a preguntar pasado este rato (por si se hizo `git init`)
    static let notRepoRetry: TimeInterval = 10 * 60

    /// Los repositorios medidos, por carpeta. Vacío hasta la primera medida
    private(set) var repos: [GitRepo] = []
    private(set) var github: [String: GitHubInfo] = [:]

    @ObservationIgnored var onNotice: (@MainActor (GitNotice) -> Void)?

    @ObservationIgnored private let git: String?
    @ObservationIgnored private let gh: String?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sessionsDirectory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let watchesFileSystem: Bool
    @ObservationIgnored private let releaseGrace: Duration
    @ObservationIgnored private let gitRunner = CommandRunner(timeout: 15)
    @ObservationIgnored private let ghRunner = CommandRunner(timeout: 20)
    @ObservationIgnored private let githubPoller = Poller()
    @ObservationIgnored private var detector = GitNoticeDetector()
    @ObservationIgnored private var states: [String: RepoState] = [:]
    @ObservationIgnored private var locations: [String: (location: GitLocation?, checkedAt: Date)] = [:]
    @ObservationIgnored private var stream: FileEventStream?
    @ObservationIgnored private var sessionWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var sessionsTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isVisible = false

    /// Lo que se sabe y se hace con cada repositorio vigilado
    private struct RepoState {
        var location: GitLocation
        var repo: GitRepo?
        var lastRefresh: Date?
        var inFlight: Task<Void, Never>?
        var scheduled: Task<Void, Never>?
        var again = false
        var ciTask: Task<Void, Never>?
        var releaseTask: Task<Void, Never>?
        /// Se está mirando si una sesión de Claude Code dejó cambios sin commit: otros `Stop` mientras tanto no repiten la medida
        var finishing = false
        var lastGitHub: Date?

        func cancelTasks() {
            inFlight?.cancel()
            scheduled?.cancel()
            ciTask?.cancel()
            releaseTask?.cancel()
        }
    }

    init(
        git: String? = GitTools.git(), gh: String? = GitTools.gh(), settings: AppSettings,
        sessionsDirectory: URL = ClaudeSessionReader.defaultDirectory, now: @escaping () -> Date = { Date() },
        watchesFileSystem: Bool = true, releaseGrace: Duration = .seconds(10 * 60)
    ) {
        self.git = git
        self.gh = gh
        self.settings = settings
        self.sessionsDirectory = sessionsDirectory
        self.now = now
        self.watchesFileSystem = watchesFileSystem
        self.releaseGrace = releaseGrace
    }

    var gitAvailable: Bool { git != nil }
    /// Está consultando `gh` ahora, con la pestaña a la vista
    var isRunning: Bool { githubPoller.isRunning }
    private var isEnabled: Bool { settings.showGit && git != nil }

    // MARK: - Ciclo de vida

    /// Empieza a vigilar. En los tests no se llama: serían los repositorios y las sesiones de verdad
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Logger.tools.info("Git: en marcha")
        observeSettings()
        watchSessions()
        scheduleReconcile()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        tearDown()
        sessionWatcher?.cancel()
        sessionWatcher = nil
        sessionsTask?.cancel()
        sessionsTask = nil
        githubPoller.stop()
        Logger.tools.info("Git: parado")
    }

    /// La pestaña Desarrollador se ve o deja de verse. Lo dice DevTools
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard visible else {
            githubPoller.stop()
            return
        }
        guard isStarted else { return }
        // Lo que se ve es lo de ahora: se vuelve a medir (con el límite de cada 30 s) y se pregunta a GitHub
        watchSessions()
        for root in states.keys { refresh(root) }
        startGitHubPolling()
    }

    private func startGitHubPolling() {
        guard isVisible, isEnabled, settings.gitUseGitHub, gh != nil else { return }
        githubPoller.start(interval: Self.githubInterval) { [weak self] _ in self?.refreshGitHub() }
    }

    // Los ajustes que cambian qué se vigila. El valor se lee dentro del seguimiento y lo que se hace con él, fuera
    private func observeSettings() {
        withObservationTracking {
            _ = settings.showGit
            _ = settings.gitFolders
            _ = settings.gitUseGitHub
            _ = settings.gitNoticeSettings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.scheduleReconcile()
                self.githubSettingChanged()
                // Los minutos o el interruptor de los commits sin subir cambian la hora a la que toca avisar
                self.scheduleDeadline()
                self.observeSettings()
            }
        }
    }

    // Con GitHub apagado, nada de lo que ya estaba en marcha le sigue preguntando: ni el seguimiento de un CI ni la comprobación de
    // una release, que podría avisar después de haberlo apagado
    private func githubSettingChanged() {
        if settings.gitUseGitHub {
            startGitHubPolling()
            return
        }
        githubPoller.stop()
        for root in states.keys {
            states[root]?.ciTask?.cancel()
            states[root]?.ciTask = nil
            states[root]?.releaseTask?.cancel()
            states[root]?.releaseTask = nil
        }
        github = [:]
    }

    private func tearDown() {
        for state in states.values { state.cancelTasks() }
        states = [:]
        stream?.stop()
        stream = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        detector = GitNoticeDetector()
        repos = []
        github = [:]
    }

    // MARK: - Qué repositorios

    /// Una sola vez a la vez: si llega otra petición mientras tanto, se repite al terminar
    private func scheduleReconcile() {
        if reconcileTask != nil {
            reconcileAgain = true
            return
        }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                reconcileAgain = false
                await reconcile()
            } while reconcileAgain
            reconcileTask = nil
        }
    }

    /// Calcula qué repositorios hay (las carpetas de Ajustes y las de las sesiones abiertas) y vigila los nuevos y deja los que
    /// ya no
    func reconcile() async {
        guard isStarted, isEnabled else {
            if isStarted { tearDown() }
            return
        }
        let directory = sessionsDirectory
        let sessions = await Task.detached { ClaudeSessionReader.read(in: directory) }.value ?? []
        let folders = settings.gitFolders + sessions.map(\.cwd).filter { !$0.isEmpty }.sorted()
        var found: [GitLocation] = []
        var seen: Set<String> = []
        for folder in folders {
            guard found.count < Self.maxRepos else { break }
            if let location = await resolve(folder), seen.insert(location.root).inserted { found.append(location) }
        }
        // Mientras se esperaba, se pudo parar o apagar
        guard isStarted, isEnabled else { return }
        locations = locations.filter { folders.contains($0.key) }
        let roots = Set(found.map(\.root))
        var changed = false
        for (root, state) in states where !roots.contains(root) {
            state.cancelTasks()
            states[root] = nil
            github[root] = nil
            detector.forget(root)
            changed = true
        }
        var added: [String] = []
        for location in found where states[location.root] == nil {
            states[location.root] = RepoState(location: location)
            added.append(location.root)
            changed = true
        }
        guard changed else { return }
        publish()
        rebuildStream()
        for root in added { startMeasure(root) }
        scheduleDeadline()
    }

    /// El repositorio al que pertenece una carpeta, o nil si no es de ninguno
    private func resolve(_ folder: String) async -> GitLocation? {
        if let cached = locations[folder], cached.location != nil || now().timeIntervalSince(cached.checkedAt) < Self.notRepoRetry {
            return cached.location
        }
        guard let git else { return nil }
        var location: GitLocation?
        if let output = try? await gitRunner.run(
            git, Self.base(folder) + ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]
        ) {
            location = GitRevParse.parse(output).map {
                GitLocation(root: Self.normalized($0.root), commonDir: Self.normalized($0.commonDir))
            }
        }
        locations[folder] = (location, now())
        return location
    }

    private static func base(_ folder: String) -> [String] {
        ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", folder]
    }

    /// Las rutas de FSEvents son las reales (`/private/var/…`), y `resolvingSymlinksInPath` de Foundation quita ese `/private`:
    /// con `realpath` se comparan con las mismas
    nonisolated static func normalized(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    // MARK: - Medir

    /// Mide un repositorio, o lo deja para dentro de unos segundos si se midió hace menos de 30 s
    func refresh(_ root: String) {
        guard let state = states[root] else { return }
        if state.inFlight != nil {
            states[root]?.again = true
            return
        }
        if let last = state.lastRefresh {
            let wait = Self.refreshGap - now().timeIntervalSince(last)
            if wait > 0 {
                if state.scheduled == nil {
                    states[root]?.scheduled = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(1))
                        guard !Task.isCancelled, let self else { return }
                        states[root]?.scheduled = nil
                        refresh(root)
                    }
                }
                return
            }
        }
        startMeasure(root)
    }

    /// Mide ya, sin esperar a los 30 s (y detrás de la medida que haya en marcha, que pudo empezar antes del último cambio)
    func refreshNow(_ root: String) async {
        while let running = states[root]?.inFlight { await running.value }
        await startMeasure(root)?.value
    }

    @discardableResult
    private func startMeasure(_ root: String) -> Task<Void, Never>? {
        guard states[root] != nil else { return nil }
        states[root]?.scheduled?.cancel()
        states[root]?.scheduled = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await measureAndApply(root)
        }
        states[root]?.inFlight = task
        return task
    }

    private func measureAndApply(_ root: String) async {
        guard let location = states[root]?.location else { return }
        let measured = await measure(location)
        // Si mientras tanto dejó de vigilarse (se canceló), no hay nada que actualizar: ni siquiera su `inFlight`, que ya puede ser
        // de otra medida de un repo que volvió a añadirse
        guard !Task.isCancelled, var state = states[root] else { return }
        let previous = state.repo
        let again = state.again
        state.inFlight = nil
        state.again = false
        state.lastRefresh = now()
        if let measured { state.repo = measured }
        states[root] = state
        if let measured { apply(measured, previous: previous) }
        publish()
        if again { refresh(root) }
    }

    // Seis o siete llamadas rápidas a git. Un repositorio sin etiquetas (`describe` sale con 128) o sin remota no es un error
    private func measure(_ location: GitLocation) async -> GitRepo? {
        guard let git else { return nil }
        let base = Self.base(location.root)
        func run(_ arguments: [String]) async -> String? {
            (try? await gitRunner.run(git, base + arguments))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let output = try? await gitRunner.run(git, base + ["status", "--porcelain=v2", "--branch"]) else {
            Logger.tools.info("Git: no se pudo medir un repositorio")
            return nil
        }
        let status = GitStatusParser.parse(output)
        // Una remota cuyo nombre empieza por «-» se tomaría por una opción: solo puede venir de la configuración del repo
        let remoteNames = (await run(["remote"]) ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("-") }
        var remote: GitHubRepo?
        if let name = remoteNames.contains("origin") ? "origin" : remoteNames.first, let url = await run(["remote", "get-url", name]) {
            remote = GitRemoteParser.github(from: url)
        }
        // Una rama que no sigue a ninguna: los commits que ninguna remota tiene
        var unpublished = 0
        if !remoteNames.isEmpty, status.upstream == nil, status.oid != nil, let count = await run(["rev-list", "--count", "HEAD", "--not", "--remotes"]) {
            unpublished = Int(count) ?? 0
        }
        // Una etiqueta que empieza por «-» se tomaría por una opción
        var tag = await run(["describe", "--tags", "--abbrev=0"]).flatMap { $0.isEmpty || $0.hasPrefix("-") ? nil : $0 }
        var sinceTag = 0
        if let found = tag {
            if let count = await run(["rev-list", "--count", "\(found)..HEAD"]) { sinceTag = Int(count) ?? 0 } else { tag = nil }
        }
        var upstreamOID: String?
        var upstreamBranch: String?
        var lastRemoteUpdate = ""
        if let upstream = status.upstream {
            // «origin/feature/x» en la remota «origin»: la rama de allí es «feature/x», y puede no llamarse como la local
            upstreamBranch = remoteNames.sorted { $0.count > $1.count }.first { upstream.hasPrefix($0 + "/") }
                .map { String(upstream.dropFirst($0.count + 1)) }
            let reference = "refs/remotes/\(upstream)"
            upstreamOID = await run(["rev-parse", "--verify", "--quiet", reference]).flatMap { $0.isEmpty ? nil : $0 }
            lastRemoteUpdate = upstreamOID == nil ? "" : (await run(["reflog", "show", "--format=%gs", "-1", reference]) ?? "")
        }
        return GitRepo(
            root: location.root, commonDir: location.commonDir, status: status, hasRemote: !remoteNames.isEmpty, unpublished: unpublished,
            remote: remote, tag: tag, sinceTag: sinceTag, upstreamOID: upstreamOID, lastRemoteUpdate: lastRemoteUpdate,
            upstreamBranch: upstreamBranch
        )
    }

    private func apply(_ repo: GitRepo, previous: GitRepo?) {
        if let notice = detector.observe(repo, at: now(), settings: settings.gitNoticeSettings) { emit(notice) }
        scheduleDeadline()
        if let previous, repo.pushed(since: previous) { trackCI(repo) }
        // Solo una etiqueta que aparece con la app en marcha, sobre el commit actual (alguien acaba de hacer `git tag`): las que ya
        // había al arrancar, o que salen al cambiar de rama, se verían en cada inicio si nunca tuvieron release
        if let previous, previous.tag != repo.tag, repo.tag != nil, repo.sinceTag == 0 { scheduleReleaseCheck(repo) }
        // Con la pestaña a la vista, lo que se acaba de descubrir se completa con `gh`
        if isVisible {
            let root = repo.id
            Task { [weak self] in await self?.fetchGitHub(root) }
        }
    }

    private func publish() {
        let measured = states.values.compactMap(\.repo).sorted { $0.root < $1.root }
        if measured != repos { repos = measured }
    }

    private func emit(_ notice: GitNotice) {
        // Sin el nombre del repositorio ni la etiqueta: son del usuario
        Logger.tools.info("Git: aviso")
        onNotice?(notice)
    }

    // MARK: - Vigilar

    private func rebuildStream() {
        stream?.stop()
        stream = nil
        guard watchesFileSystem else { return }
        var paths: Set<String> = []
        for state in states.values {
            paths.insert(state.location.root)
            // En un worktree el `.git` común está fuera de la carpeta: ahí se mueven las ramas y las etiquetas
            if !Self.contains(state.location.commonDir, in: state.location.root) { paths.insert(state.location.commonDir) }
        }
        stream = FileEventStream(paths: paths.sorted(), latency: Self.fileLatency) { [weak self] changed in
            self?.filesChanged(changed)
        }
    }

    private func filesChanged(_ paths: [String]) {
        var dirty: Set<String> = []
        for path in paths where !Self.isNoise(path) {
            for (root, state) in states where Self.contains(path, in: state.location.root) || Self.contains(path, in: state.location.commonDir) {
                dirty.insert(root)
            }
        }
        for root in dirty { refresh(root) }
    }

    /// Lo que cambia sin cambiar el repositorio: los objetos que git escribe y los candados que pone un momento
    nonisolated static func isNoise(_ path: String) -> Bool {
        path.contains("/.git/objects") || path.hasSuffix(".lock") || path.hasSuffix(".lock/")
    }

    nonisolated static func contains(_ path: String, in folder: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }

    // La carpeta de las sesiones de Claude Code cambia al abrir o cerrar una sesión (y, por cómo se reescriben, también con su
    // estado): se agrupa lo que llegue en 3 s y se vuelve a calcular qué repositorios hay
    private func watchSessions() {
        guard sessionWatcher == nil else { return }
        let descriptor = open(sessionsDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sessionsChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sessionWatcher = source
    }

    private func sessionsChanged() {
        guard isStarted, isEnabled, sessionsTask == nil else { return }
        sessionsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionsDebounce, tolerance: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            sessionsTask = nil
            scheduleReconcile()
        }
    }

    // MARK: - Avisos con hora

    // Los commits sin subir avisan cuando pasa su tiempo, y nada lo dispara por sí solo: una sola espera hasta la hora más
    // próxima. Al llegar, se vuelve a medir (el push pudo ser hace un momento) y la medida decide si avisa
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = detector.nextDeadline(settings: settings.gitNoticeSettings) else { return }
        // Como mínimo un minuto: si la medida falla, no se vuelve a intentar sin pausa
        let wait = max(60, deadline.timeIntervalSince(now()))
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            deadlineTask = nil
            for repo in repos where repo.pendingPush > 0 { await refreshNow(repo.id) }
            scheduleDeadline()
        }
    }

    /// Una sesión de Claude Code terminó (`Stop` llega con cada turno): si su repositorio tiene cambios sin commit, se avisa una
    /// vez, hasta que vuelva a estar limpio. Los hooks solo traen el nombre de la carpeta; la ruta se saca de una lectura nueva de
    /// las sesiones, porque con la isla cerrada la que se tenía puede estar vieja
    func claudeFinished(sessionID: String) {
        guard isStarted, isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            let directory = sessionsDirectory
            let sessions = await Task.detached { ClaudeSessionReader.read(in: directory) }.value
            guard let cwd = sessions?.first(where: { $0.sessionID == sessionID })?.cwd, !cwd.isEmpty,
                  let location = await resolve(cwd), let state = states[location.root], !state.finishing else { return }
            // Varios `Stop` seguidos (cualquier proceso puede mandar tantos como quiera) hacen una sola medida
            states[location.root]?.finishing = true
            await refreshNow(location.root)
            states[location.root]?.finishing = false
            guard let repo = states[location.root]?.repo,
                  let notice = detector.sessionFinished(in: repo, settings: settings.gitNoticeSettings) else { return }
            emit(notice)
        }
    }

    // MARK: - GitHub

    // Un repositorio detrás de otro: con varios, lanzarlos todos juntos serían decenas de procesos `gh` a la vez
    private func refreshGitHub() {
        let roots = states.keys.sorted()
        Task { [weak self] in
            for root in roots {
                guard let self, !Task.isCancelled else { return }
                await fetchGitHub(root)
            }
        }
    }

    /// Releases, CI del commit actual y PR abiertos de un repositorio. Un campo que no se pudo medir se queda como estaba
    private func fetchGitHub(_ root: String) async {
        guard settings.gitUseGitHub, let gh, let repo = states[root]?.repo, let remote = repo.remote else { return }
        if let last = states[root]?.lastGitHub, now().timeIntervalSince(last) < Self.githubFreshness { return }
        states[root]?.lastGitHub = now()
        // El CI es el de lo que hay en GitHub (el último commit subido, en la rama de allí), no el de un commit que todavía solo
        // está en tu máquina
        let branch = repo.upstreamBranch ?? repo.status.branch
        let sha = repo.upstreamOID ?? repo.status.oid
        async let releases = fetchReleases(of: remote, gh: gh)
        async let runs = fetchRuns(of: remote, branch: branch, gh: gh)
        async let pulls = fetchPullRequests(of: remote, gh: gh)
        let (newReleases, newRuns, newPulls) = await (releases, runs, pulls)
        // Si mientras tanto se apagó GitHub o se dejó de vigilar el repo, no se publica nada
        guard settings.gitUseGitHub, states[root] != nil else { return }
        var info = github[root] ?? GitHubInfo()
        if let newReleases { info.published = CIResolver.published(newReleases) }
        // Mientras se sigue el CI de un push, ese seguimiento es quien lo dice
        if states[root]?.ciTask == nil, let sha, let newRuns { info.ci = CIResolver.state(of: newRuns, sha: sha) }
        if let newPulls { info.openPRs = newPulls }
        if info != github[root] { github[root] = info }
    }

    // Tras un push, cada 30 s hasta que el CI de ese commit termina, 30 min como mucho. Si en 3 min no apareció ningún flujo de
    // trabajo, el repositorio no tiene CI (o no para esa rama) y se deja
    // Es el commit que se subió (a lo que apunta la rama remota), no HEAD: con otro commit encima, el de HEAD todavía no está en
    // GitHub. La rama es la de la remota, que puede llamarse distinto de la local
    private func trackCI(_ repo: GitRepo) {
        guard settings.gitUseGitHub, let gh, let remote = repo.remote, let branch = repo.upstreamBranch ?? repo.status.branch,
              let sha = repo.upstreamOID ?? repo.status.oid else { return }
        let root = repo.id
        states[root]?.ciTask?.cancel()
        let started = now()
        states[root]?.ciTask = Task { [weak self] in
            var seen = false
            while !Task.isCancelled {
                guard let self, settings.gitUseGitHub else { return }
                let elapsed = now().timeIntervalSince(started)
                let fetched = await fetchRuns(of: remote, branch: branch, gh: gh)
                // Cancelada (otro push, GitHub apagado, repo quitado): no toca el estado del seguimiento que la sustituyó
                guard !Task.isCancelled else { return }
                if let runs = fetched {
                    if let state = CIResolver.state(of: runs, sha: sha) {
                        seen = true
                        setCI(state, for: root)
                        if state != .running {
                            states[root]?.ciTask = nil
                            if let repo = states[root]?.repo,
                               let notice = detector.ciFinished(in: repo, sha: sha, state: state, settings: settings.gitNoticeSettings) {
                                emit(notice)
                            }
                            return
                        }
                    } else if !seen, elapsed > Self.ciNoRunLimit {
                        states[root]?.ciTask = nil
                        return
                    }
                }
                if elapsed > Self.ciLimit {
                    states[root]?.ciTask = nil
                    return
                }
                try? await Task.sleep(for: Self.ciInterval, tolerance: .seconds(5))
            }
        }
    }

    private func setCI(_ state: CIState, for root: String) {
        var info = github[root] ?? GitHubInfo()
        guard info.ci != state else { return }
        info.ci = state
        github[root] = info
    }

    // Una etiqueta nueva no tiene release el mismo instante: se mira pasados unos minutos, una vez por etiqueta
    private func scheduleReleaseCheck(_ repo: GitRepo) {
        let root = repo.id
        states[root]?.releaseTask?.cancel()
        states[root]?.releaseTask = nil
        guard settings.gitUseGitHub, let gh, let remote = repo.remote, repo.tag != nil else { return }
        let grace = releaseGrace
        states[root]?.releaseTask = Task { [weak self] in
            try? await Task.sleep(for: grace, tolerance: .seconds(30))
            guard !Task.isCancelled, let self, settings.gitUseGitHub else { return }
            let fetched = await fetchReleases(of: remote, gh: gh)
            guard !Task.isCancelled, settings.gitUseGitHub, let current = states[root]?.repo else { return }
            let published = fetched.map(CIResolver.published)
            if let published, github[root]?.published != published {
                var info = github[root] ?? GitHubInfo()
                info.published = published
                github[root] = info
            }
            if let notice = detector.releaseChecked(in: current, published: published, settings: settings.gitNoticeSettings) { emit(notice) }
        }
    }

    private func fetchReleases(of remote: GitHubRepo, gh: String) async -> [GitHubRelease]? {
        await ghData(gh, ["release", "list", "-R", remote.slug, "--limit", "20", "--json", "tagName,isDraft"]).flatMap(GitHubParser.releases)
    }

    private func fetchRuns(of remote: GitHubRepo, branch: String?, gh: String) async -> [GitHubRun]? {
        guard let branch else { return nil }
        return await ghData(gh, ["run", "list", "-R", remote.slug, "--branch", branch, "--limit", "20", "--json", "headSha,status,conclusion"])
            .flatMap(GitHubParser.runs)
    }

    private func fetchPullRequests(of remote: GitHubRepo, gh: String) async -> Int? {
        await ghData(gh, ["pr", "list", "-R", remote.slug, "--state", "open", "--limit", "100", "--json", "number"]).flatMap(GitHubParser.count)
    }

    /// nil si `gh` falló: sin red, sin sesión o sin permiso. El mensaje no va al log: lleva el nombre del repositorio
    private func ghData(_ gh: String, _ arguments: [String]) async -> Data? {
        do {
            return Data(try await ghRunner.run(gh, arguments).utf8)
        } catch {
            Logger.tools.info("Git: gh no contestó")
            return nil
        }
    }

    // MARK: - Lo que se pulsa

    func repo(withID id: String) -> GitRepo? {
        states[id]?.repo
    }

    /// Hay un CI en seguimiento para ese repositorio (para los tests)
    func isTrackingCI(_ root: String) -> Bool {
        states[root]?.ciTask != nil
    }

    #if DEBUG
    /// Lo que había antes de la demo, para devolverlo
    @ObservationIgnored private var beforeDemo: (repos: [GitRepo], github: [String: GitHubInfo])?

    /// Para el snapshot de la isla: tres repositorios inventados, sin tocar nada
    func injectDemo() {
        if beforeDemo == nil { beforeDemo = (repos, github) }
        func repo(_ name: String, branch: String, ahead: Int?, dirty: Int, tag: String?) -> GitRepo {
            GitRepo(
                root: "/demo/\(name)", commonDir: "/demo/\(name)/.git",
                status: GitStatus(branch: branch, oid: "abc", upstream: "origin/\(branch)", ahead: ahead, behind: 0, changed: dirty),
                hasRemote: true, unpublished: 0, remote: GitHubRepo(owner: "demo", name: name), tag: tag, sinceTag: 2,
                upstreamOID: "def", lastRemoteUpdate: ""
            )
        }
        repos = [
            repo("tienda", branch: "feature/carrito", ahead: 3, dirty: 2, tag: "v1.4.0"),
            repo("api", branch: "main", ahead: 0, dirty: 0, tag: "v2.0.1"), repo("docs", branch: "main", ahead: 0, dirty: 0, tag: nil),
        ]
        github = [
            "/demo/tienda": GitHubInfo(ci: .failed, published: ["v1.3.0"], openPRs: 2),
            "/demo/api": GitHubInfo(ci: .passed, published: ["v2.0.1"], openPRs: 0),
        ]
    }

    /// Quita lo inyectado y devuelve lo que se había medido de verdad
    func resetInjected() {
        guard let beforeDemo else { return }
        (repos, github) = beforeDemo
        self.beforeDemo = nil
    }
    #endif
}
