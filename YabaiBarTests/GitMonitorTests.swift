import Foundation
import Testing
@testable import YabaiBar

// Con git de verdad, en repositorios temporales con una remota local (una carpeta `--bare`), y con un `gh` falso que contesta lo
// que el test deja en una carpeta y apunta lo que se le pide. Nunca se toca el repositorio del proyecto ni la red.

/// Un repositorio temporal y su remota. La remota de GitHub (la que se lee) es falsa: `fetch url` apunta a github.com y el push
/// va a la carpeta local con `pushurl`
struct GitFixtureRepo {
    let root: URL
    let work: URL
    let remote: URL

    static let environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    ]

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: try #require(GitTools.git()))
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un repositorio con un commit, subido a su remota
    static func make() throws -> GitFixtureRepo {
        let root = FileManager.default.temporaryDirectory.appending(path: "git-tests-\(UUID().uuidString)")
        let remote = root.appending(path: "remote.git")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main"], in: remote)
        try git(["init", "-q", "-b", "main"], in: work)
        let repo = GitFixtureRepo(root: root, work: work, remote: remote)
        try repo.write("a.txt", "uno\n")
        try git(["add", "."], in: work)
        try git(["commit", "-q", "-m", "uno"], in: work)
        try git(["remote", "add", "origin", remote.path], in: work)
        try git(["push", "-q", "-u", "origin", "main"], in: work)
        // La remota que se lee es de GitHub; el push sigue yendo a la carpeta local
        try git(["config", "remote.origin.pushurl", remote.path], in: work)
        try git(["remote", "set-url", "origin", "git@github.com:acme/widgets.git"], in: work)
        return repo
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: work.appending(path: name), atomically: true, encoding: .utf8)
    }

    func commit(_ message: String = "otro") throws {
        try write("a.txt", "\(message) \(UUID().uuidString)\n")
        try Self.git(["commit", "-q", "-am", message], in: work)
    }

    var head: String { get throws { try Self.git(["rev-parse", "HEAD"], in: work) } }
    /// La ruta real, como la da git
    var rootPath: String { GitMonitor.normalized(work.path) }
}

/// Un `gh` falso: contesta con lo que haya en su carpeta (`releases.json`, `runs.json`, `prs.json`) o falla, y apunta cada llamada
struct FakeGitHub {
    let directory: URL
    let executable: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "fake-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = try FakeYabai.make(
            """
            d='\(directory.path)'
            echo "$@" >> "$d/calls.log"
            case "$1" in
              release) f="$d/releases.json" ;;
              run) f="$d/runs.json" ;;
              pr) f="$d/prs.json" ;;
            esac
            if [ -f "$f" ]; then cat "$f"; else echo "gh: sin conexión" >&2; exit 1; fi
            """
        )
    }

    func answer(_ file: String, _ json: String) throws {
        try json.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
    }

    var calls: [String] {
        ((try? String(contentsOf: directory.appending(path: "calls.log"), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
    }
}

@MainActor
struct GitMonitorTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    final class Seen {
        var paths: [String] = []
    }

    private func settings(folders: [String] = []) -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "git-tests-\(UUID().uuidString)")!)
        settings.gitFolders = folders
        return settings
    }

    private func monitor(
        _ settings: AppSettings, gh: String? = nil, sessions: URL? = nil, clock: Clock = Clock(), releaseGrace: Duration = .seconds(600)
    ) throws -> GitMonitor {
        _ = try #require(GitTools.git())
        return GitMonitor(
            git: GitTools.git(), gh: gh, settings: settings,
            sessionsDirectory: sessions ?? FileManager.default.temporaryDirectory.appending(path: "no-sessions-\(UUID().uuidString)"),
            now: { clock.now }, watchesFileSystem: false, releaseGrace: releaseGrace
        )
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Arranca y espera a que el repositorio salga medido
    private func started(_ monitor: GitMonitor, count: Int = 1) async -> Bool {
        monitor.start()
        await monitor.reconcile()
        return await waitUntil { monitor.repos.count == count }
    }

    // MARK: Medir

    @Test func measuresWhatGitSays() async throws {
        let fixture = try GitFixtureRepo.make()
        try GitFixtureRepo.git(["tag", "v1.0.0"], in: fixture.work)
        try fixture.commit("dos")
        try fixture.commit("tres")
        try fixture.write("a.txt", "cambiado sin commit\n")
        try fixture.write("nuevo.txt", "sin seguimiento\n")
        let monitor = try monitor(settings(folders: [fixture.work.appending(path: "sub-que-no-existe").path, fixture.work.path]))
        defer { monitor.stop() }
        #expect(await started(monitor))
        let repo = try #require(monitor.repos.first)
        #expect(repo.id == fixture.rootPath)
        #expect(repo.name == "work")
        #expect(repo.status.branch == "main")
        #expect(repo.status.ahead == 2 && repo.status.behind == 0)
        #expect(repo.status.upstream == "origin/main")
        #expect(repo.upstreamBranch == "main")
        #expect(repo.status.dirty == 2)
        #expect(repo.pendingPush == 2)
        #expect(repo.hasRemote)
        #expect(repo.remote == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(repo.tag == "v1.0.0")
        #expect(repo.sinceTag == 2)
        #expect(repo.upstreamOID != nil && repo.upstreamOID != repo.status.oid)
        // Con la fila del módulo, de punta a punta
        let row = GitRows.content(of: monitor.repos, github: [:]).rows[0]
        #expect(row.detail == "main ↑2 ●2")
        #expect(row.trailing == "v1.0.0 +2")
    }

    @Test func aFolderInsideARepositoryBelongsToIt() async throws {
        let fixture = try GitFixtureRepo.make()
        let inner = fixture.work.appending(path: "carpeta/interna")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let monitor = try monitor(settings(folders: [inner.path, fixture.work.path]))
        defer { monitor.stop() }
        // Las dos son el mismo repositorio
        #expect(await started(monitor))
        #expect(monitor.repos.first?.id == fixture.rootPath)
    }

    @Test func aBranchWithoutUpstreamCountsTheCommitsNoRemoteHas() async throws {
        let fixture = try GitFixtureRepo.make()
        try GitFixtureRepo.git(["checkout", "-q", "-b", "feature"], in: fixture.work)
        try fixture.commit("uno")
        try fixture.commit("dos")
        let monitor = try monitor(settings(folders: [fixture.work.path]))
        defer { monitor.stop() }
        #expect(await started(monitor))
        let repo = try #require(monitor.repos.first)
        #expect(repo.status.upstream == nil && repo.status.ahead == nil)
        #expect(repo.unpublished == 2)
        #expect(repo.pendingPush == 2)
    }

    @Test func aRepositoryWithoutTagsOrCommitsIsNotAnError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "git-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try GitFixtureRepo.git(["init", "-q", "-b", "trunk"], in: root)
        let monitor = try monitor(settings(folders: [root.path]))
        defer { monitor.stop() }
        #expect(await started(monitor))
        let repo = try #require(monitor.repos.first)
        #expect(repo.status.oid == nil && repo.status.branch == "trunk")
        #expect(repo.tag == nil && repo.sinceTag == 0 && !repo.hasRemote && repo.remote == nil)
        #expect(repo.pendingPush == 0)
    }

    @Test func aWorktreeIsItsOwnRowAndSharesTheCommonDir() async throws {
        let fixture = try GitFixtureRepo.make()
        let other = fixture.root.appending(path: "otro-arbol")
        try GitFixtureRepo.git(["worktree", "add", "-q", "-b", "otra", other.path], in: fixture.work)
        let monitor = try monitor(settings(folders: [fixture.work.path, other.path]))
        defer { monitor.stop() }
        #expect(await started(monitor, count: 2))
        #expect(Set(monitor.repos.map(\.name)) == ["work", "otro-arbol"])
        #expect(Set(monitor.repos.map(\.commonDir)).count == 1)
        #expect(monitor.repos.first { $0.name == "otro-arbol" }?.status.branch == "otra")
    }

    @Test func notARepositoryAndNoGitGiveNothing() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "no-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let monitor = try monitor(settings(folders: [empty.path]))
        defer { monitor.stop() }
        monitor.start()
        await monitor.reconcile()
        #expect(monitor.repos.isEmpty)
        // Sin git, no se vigila nada y el módulo lo dice
        let without = GitMonitor(git: nil, gh: nil, settings: settings(folders: [empty.path]))
        without.start()
        await without.reconcile()
        #expect(!without.gitAvailable && without.repos.isEmpty)
        #expect(GitRows.content(of: [], github: [:], gitAvailable: without.gitAvailable).notice?.title == "No se encuentra git")
        without.stop()
    }

    @Test func turningTheModuleOffWatchesNothing() async throws {
        let fixture = try GitFixtureRepo.make()
        let settings = settings(folders: [fixture.work.path])
        let monitor = try monitor(settings)
        defer { monitor.stop() }
        #expect(await started(monitor))
        settings.showGit = false
        await monitor.reconcile()
        #expect(monitor.repos.isEmpty)
        settings.showGit = true
        await monitor.reconcile()
        #expect(await waitUntil { monitor.repos.count == 1 })
    }

    @Test func aFolderLeavingTheListStopsBeingWatched() async throws {
        let fixture = try GitFixtureRepo.make()
        let settings = settings(folders: [fixture.work.path])
        let monitor = try monitor(settings)
        defer { monitor.stop() }
        #expect(await started(monitor))
        settings.gitFolders = []
        await monitor.reconcile()
        #expect(monitor.repos.isEmpty)
    }

    // MARK: Avisos

    // Los hooks de Claude Code solo dicen la carpeta de la sesión: la ruta se saca de `~/.claude/sessions`
    @Test func whenASessionFinishesItsUncommittedChangesAreAnnouncedOnce() async throws {
        let fixture = try GitFixtureRepo.make()
        let sessions = try ClaudeTestSupport.temporaryDirectory().appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = ["pid": getpid(), "sessionId": "s1", "cwd": fixture.work.path, "status": "idle", "entrypoint": "cli"]
        try JSONSerialization.data(withJSONObject: record).write(to: sessions.appending(path: "\(getpid()).json"))
        let monitor = try monitor(settings(), sessions: sessions)
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        // El repositorio sale de la carpeta de la sesión, sin ninguna carpeta en Ajustes
        #expect(await started(monitor))
        #expect(monitor.repos.first?.id == fixture.rootPath)

        try fixture.write("a.txt", "cambiado\n")
        monitor.claudeFinished(sessionID: "s1")
        #expect(await waitUntil { notices.count == 1 })
        #expect(notices.first == GitNotice(repo: "work", kind: .uncommitted(files: 1)))
        // `Stop` llega con cada turno: no se repite mientras siga sin commit
        monitor.claudeFinished(sessionID: "s1")
        try await Task.sleep(for: .milliseconds(600))
        #expect(notices.count == 1)
        // Una sesión que no existe, o sin cambios, no avisa
        monitor.claudeFinished(sessionID: "otra")
        // Limpio y vuelta a empezar
        try GitFixtureRepo.git(["commit", "-q", "-am", "limpio"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        try fixture.write("a.txt", "cambiado otra vez\n")
        monitor.claudeFinished(sessionID: "s1")
        #expect(await waitUntil { notices.count == 2 })
    }

    @Test func commitsLeftUnpushedAreAnnouncedAfterTheThreshold() async throws {
        let fixture = try GitFixtureRepo.make()
        let clock = Clock()
        let monitor = try monitor(settings(folders: [fixture.work.path]), clock: clock)
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        try fixture.commit("sin subir")
        await monitor.refreshNow(fixture.rootPath)
        #expect(monitor.repos.first?.pendingPush == 1)
        #expect(notices.isEmpty)
        clock.now += 29 * 60
        await monitor.refreshNow(fixture.rootPath)
        #expect(notices.isEmpty)
        clock.now += 2 * 60
        await monitor.refreshNow(fixture.rootPath)
        #expect(notices == [GitNotice(repo: "work", kind: .unpushed(commits: 1))])
        // Una vez
        clock.now += 3600
        await monitor.refreshNow(fixture.rootPath)
        #expect(notices.count == 1)
    }

    @Test func aPushFollowsTheCIAndAnnouncesHowItEnded() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable)
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        try fixture.commit("para subir")
        await monitor.refreshNow(fixture.rootPath)
        // Un commit sin subir no mira el CI
        #expect(gh.calls.filter { $0.hasPrefix("run") }.isEmpty)
        let sha = try fixture.head
        try gh.answer("runs.json", #"[{"headSha":"\#(sha)","status":"completed","conclusion":"failure"}]"#)
        try GitFixtureRepo.git(["push", "-q", "origin", "main"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        #expect(await waitUntil { notices.count == 1 })
        #expect(notices.first == GitNotice(repo: "work", kind: .ci(.failed)))
        #expect(monitor.github[fixture.rootPath]?.ci == .failed)
        // La llamada lleva el repositorio de la remota y la rama, y nunca el nombre de la carpeta
        let call = try #require(gh.calls.first { $0.hasPrefix("run list") })
        #expect(call.contains("-R acme/widgets") && call.contains("--branch main"))
    }

    // Traer de la remota lo que otro subió no es un push: no se sigue ningún CI
    @Test func aFetchIsNotAPush() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable)
        defer { monitor.stop() }
        #expect(await started(monitor))
        let other = fixture.root.appending(path: "otro-clon")
        try GitFixtureRepo.git(["clone", "-q", fixture.remote.path, other.path], in: fixture.root)
        try "de otro\n".write(to: other.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try GitFixtureRepo.git(["commit", "-q", "-am", "de otro"], in: other)
        try GitFixtureRepo.git(["push", "-q", "origin", "main"], in: other)
        // La remota de este repositorio es falsa: se trae de la carpeta local
        try GitFixtureRepo.git(["fetch", "-q", fixture.remote.path, "+main:refs/remotes/origin/main"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        let repo = try #require(monitor.repos.first)
        #expect(repo.status.behind == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(gh.calls.isEmpty)
    }

    // Si gh falla, no se sabe nada: ni CI roto ni etiqueta sin release
    @Test func whenGitHubFailsNothingIsAnnounced() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable, releaseGrace: .milliseconds(50))
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        try fixture.commit("para subir")
        try GitFixtureRepo.git(["tag", "v1.0.0"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        try GitFixtureRepo.git(["push", "-q", "origin", "main"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        #expect(await waitUntil { gh.calls.contains { $0.hasPrefix("run list") } && gh.calls.contains { $0.hasPrefix("release list") } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(notices.isEmpty)
        #expect(monitor.github[fixture.rootPath]?.ci == nil)
        #expect(monitor.github[fixture.rootPath]?.published == nil)
    }

    @Test func aNewTagWithoutReleaseIsAnnouncedAfterTheGracePeriod() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        try gh.answer("releases.json", #"[{"tagName":"v0.9.0","isDraft":false},{"tagName":"v1.0.0","isDraft":true}]"#)
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable, releaseGrace: .milliseconds(50))
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        // Alguien acaba de hacer `git tag` con la app en marcha
        try GitFixtureRepo.git(["tag", "v1.0.0"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        // Un borrador no cuenta como publicada
        #expect(await waitUntil { notices.count == 1 })
        #expect(notices.first == GitNotice(repo: "work", kind: .unreleased(tag: "v1.0.0")))
        #expect(monitor.github[fixture.rootPath]?.published == ["v0.9.0"])
    }

    @Test func aPublishedTagIsNotAnnounced() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        try gh.answer("releases.json", #"[{"tagName":"v1.0.0","isDraft":false}]"#)
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable, releaseGrace: .milliseconds(50))
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        try GitFixtureRepo.git(["tag", "v1.0.0"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        #expect(await waitUntil { gh.calls.contains { $0.hasPrefix("release list") } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(notices.isEmpty)
    }

    // Una etiqueta que ya estaba al arrancar, sin release, no avisa en cada inicio: solo las que aparecen con la app en marcha
    @Test func aTagThatWasAlreadyThereAtStartupIsNotAnnounced() async throws {
        let fixture = try GitFixtureRepo.make()
        try GitFixtureRepo.git(["tag", "v1.0.0"], in: fixture.work)
        let gh = try FakeGitHub()
        try gh.answer("releases.json", "[]")
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable, releaseGrace: .milliseconds(20))
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        try await Task.sleep(for: .milliseconds(400))
        #expect(notices.isEmpty)
        #expect(gh.calls.isEmpty)
        // Ni al volver a medir sin que la etiqueta cambie
        await monitor.refreshNow(fixture.rootPath)
        try await Task.sleep(for: .milliseconds(200))
        #expect(gh.calls.isEmpty)
    }

    // El CI que se sigue es el del commit que se subió, aunque ya haya otro encima en tu máquina cuando la app se entera
    @Test func theCIFollowedIsThatOfTheCommitThatWasPushed() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable)
        defer { monitor.stop() }
        var notices: [GitNotice] = []
        monitor.onNotice = { notices.append($0) }
        #expect(await started(monitor))
        try fixture.commit("el que se sube")
        let pushed = try fixture.head
        try GitFixtureRepo.git(["push", "-q", "origin", "main"], in: fixture.work)
        // Otro commit antes de que la app mida: HEAD ya no es lo que hay en GitHub
        try fixture.commit("encima, sin subir")
        #expect(try fixture.head != pushed)
        try gh.answer("runs.json", #"[{"headSha":"\#(pushed)","status":"completed","conclusion":"failure"}]"#)
        await monitor.refreshNow(fixture.rootPath)
        #expect(await waitUntil { notices.count == 1 })
        #expect(notices.first == GitNotice(repo: "work", kind: .ci(.failed)))
        #expect(monitor.repos.first?.upstreamOID == pushed)
    }

    // La rama de la remota puede llamarse distinto de la local: es la que se pregunta a gh
    @Test func theRemoteBranchNameIsTheOneAskedOfGitHub() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable)
        defer { monitor.stop() }
        monitor.setVisible(true)
        try GitFixtureRepo.git(["checkout", "-q", "-b", "local"], in: fixture.work)
        try GitFixtureRepo.git(["push", "-q", "-u", "origin", "local:otra/rama"], in: fixture.work)
        #expect(await started(monitor))
        #expect(monitor.repos.first?.upstreamBranch == "otra/rama")
        #expect(await waitUntil { gh.calls.contains { $0.hasPrefix("run list") } })
        let call = try #require(gh.calls.first { $0.hasPrefix("run list") })
        #expect(call.contains("--branch otra/rama") && !call.contains("--branch local"))
    }

    // Apagar «Consultar GitHub con gh» corta lo que ya estaba en marcha: el seguimiento de un CI no sigue preguntando
    @Test func turningGitHubOffStopsTheCITracking() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let settings = settings(folders: [fixture.work.path])
        let monitor = try monitor(settings, gh: gh.executable)
        defer { monitor.stop() }
        #expect(await started(monitor))
        try fixture.commit("para subir")
        await monitor.refreshNow(fixture.rootPath)
        try gh.answer("runs.json", #"[{"headSha":"\#(try fixture.head)","status":"in_progress","conclusion":""}]"#)
        try GitFixtureRepo.git(["push", "-q", "origin", "main"], in: fixture.work)
        await monitor.refreshNow(fixture.rootPath)
        #expect(await waitUntil { monitor.isTrackingCI(fixture.rootPath) && monitor.github[fixture.rootPath]?.ci == .running })
        settings.gitUseGitHub = false
        #expect(await waitUntil { !monitor.isTrackingCI(fixture.rootPath) })
        #expect(monitor.github.isEmpty)
    }

    @Test func withGitHubOffNothingIsAskedOfGh() async throws {
        let fixture = try GitFixtureRepo.make()
        try GitFixtureRepo.git(["tag", "v1.0.0"], in: fixture.work)
        let gh = try FakeGitHub()
        let settings = settings(folders: [fixture.work.path])
        settings.gitUseGitHub = false
        let monitor = try monitor(settings, gh: gh.executable, releaseGrace: .milliseconds(20))
        defer { monitor.stop() }
        monitor.setVisible(true)
        #expect(await started(monitor))
        try await Task.sleep(for: .milliseconds(400))
        #expect(gh.calls.isEmpty)
        #expect(!monitor.isRunning)
    }

    // Con la pestaña a la vista, lo de gh se completa y se vuelve a pedir cada minuto
    @Test func withTheTabVisibleTheRowsGetTheirGitHubData() async throws {
        let fixture = try GitFixtureRepo.make()
        let gh = try FakeGitHub()
        let sha = try fixture.head
        try gh.answer("releases.json", #"[{"tagName":"v1.0.0","isDraft":false}]"#)
        try gh.answer("runs.json", #"[{"headSha":"\#(sha)","status":"in_progress","conclusion":""}]"#)
        try gh.answer("prs.json", #"[{"number":1},{"number":2},{"number":3}]"#)
        let monitor = try monitor(settings(folders: [fixture.work.path]), gh: gh.executable)
        defer { monitor.stop() }
        monitor.start()
        monitor.setVisible(true)
        #expect(monitor.isRunning)
        await monitor.reconcile()
        #expect(await waitUntil { monitor.github[fixture.rootPath]?.openPRs == 3 })
        let info = try #require(monitor.github[fixture.rootPath])
        #expect(info.ci == .running && info.published == ["v1.0.0"])
        let row = GitRows.content(of: monitor.repos, github: monitor.github).rows[0]
        #expect(row.detail == "main · 3 PR")
        #expect(row.trailing == "CI …")
        // Al cerrar la pestaña, deja de preguntar
        monitor.setVisible(false)
        #expect(!monitor.isRunning)
    }

    // MARK: Vigilar

    @Test func noiseIsWhatGitWritesByItself() {
        #expect(GitMonitor.isNoise("/r/.git/objects/ab"))
        #expect(GitMonitor.isNoise("/r/.git/index.lock"))
        #expect(GitMonitor.isNoise("/r/.git/refs/heads/main.lock/"))
        #expect(!GitMonitor.isNoise("/r/.git/refs/heads"))
        #expect(!GitMonitor.isNoise("/r/src/Cargo.lockfile"))
        #expect(GitMonitor.contains("/r/src/a.swift", in: "/r"))
        #expect(GitMonitor.contains("/r/", in: "/r"))
        #expect(GitMonitor.contains("/r", in: "/r/"))
        #expect(!GitMonitor.contains("/repo/src", in: "/r"))
    }

    @Test func theFileStreamReportsAChangeInsideAWatchedFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = GitMonitor.normalized(folder.path)
        let seen = Seen()
        let stream = try #require(FileEventStream(paths: [real], latency: 0.1) { seen.paths += $0 })
        defer { stream.stop() }
        // El sistema tarda un instante en empezar a contar: lo que se escribe justo al crear el flujo puede no llegar
        try await Task.sleep(for: .milliseconds(500))
        var arrived = false
        for attempt in 0..<3 where !arrived {
            try "a\(attempt)\n".write(to: folder.appending(path: "nuevo\(attempt).txt"), atomically: true, encoding: .utf8)
            arrived = await waitUntil(timeout: .seconds(3)) { seen.paths.contains { GitMonitor.contains($0, in: real) } }
        }
        #expect(arrived)
        #expect(FileEventStream(paths: [], latency: 1) { _ in } == nil)
    }
}
