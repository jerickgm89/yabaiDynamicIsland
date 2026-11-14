import Foundation
import Testing
@testable import YabaiBar

// Los git-status-*.txt son salida real de `git status --porcelain=v2 --branch` (de un repositorio temporal, con nombres de
// archivo inventados). gh-release-list.json es el formato real de `gh release list --json tagName,isDraft` con un borrador
// añadido a mano; gh-run-list.json y gh-pr-list.json están escritos a mano con el formato de `gh run list --json
// headSha,status,conclusion` y `gh pr list --json number`, porque el repositorio del usuario no tiene flujos de trabajo ni PR
struct GitParsingTests {
    @Test func readsTheStatusOfABranchThatFollowsAnother() throws {
        let status = GitStatusParser.parse(try Fixture.text("git-status-ahead"))
        #expect(status.branch == "main")
        #expect(status.oid == "c732859190c67124ae97f275dfe3a424414a4645")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2 && status.behind == 1)
        // Un cambio, un renombrado y un conflicto; dos archivos sin seguimiento (uno con espacios en la ruta)
        #expect(status.changed == 3)
        #expect(status.untracked == 2)
        #expect(status.dirty == 5)
    }

    @Test func aBranchWithoutUpstreamHasNoCounts() throws {
        let status = GitStatusParser.parse(try Fixture.text("git-status-no-upstream"))
        #expect(status.branch == "feature")
        #expect(status.upstream == nil && status.ahead == nil && status.behind == nil)
        #expect(status.dirty == 1)
    }

    @Test func aDetachedHeadHasNoBranch() throws {
        let status = GitStatusParser.parse(try Fixture.text("git-status-detached"))
        #expect(status.branch == nil)
        #expect(status.oid == "850b23c06e2390dbe721991cfda353607b192480")
        #expect(status.dirty == 0)
    }

    @Test func aRepositoryWithoutCommitsHasNoOID() throws {
        let status = GitStatusParser.parse(try Fixture.text("git-status-initial"))
        #expect(status.oid == nil)
        #expect(status.branch == "trunk")
    }

    @Test func garbageGivesAnEmptyStatus() {
        #expect(GitStatusParser.parse("") == GitStatus())
        #expect(GitStatusParser.parse("fatal: not a git repository") == GitStatus())
        // Una línea de archivo cuyo tipo no se conoce, o sin espacio detrás, no cuenta
        #expect(GitStatusParser.parse("! ignored.txt\n1x raro\n?").dirty == 0)
    }

    @Test func revParseNeedsTwoAbsolutePaths() {
        #expect(GitRevParse.parse("/Users/u/repo\n/Users/u/repo/.git\n") == GitLocation(root: "/Users/u/repo", commonDir: "/Users/u/repo/.git"))
        // En un worktree, el `.git` común es el de la carpeta principal
        #expect(GitRevParse.parse("/w/feature\n/w/main/.git")?.commonDir == "/w/main/.git")
        #expect(GitRevParse.parse("/Users/u/repo\n") == nil)
        #expect(GitRevParse.parse("relative\n.git") == nil)
        #expect(GitRevParse.parse("") == nil)
    }

    @Test(arguments: [
        "git@github.com:acme/widgets.git", "git@github.com:acme/widgets", "https://github.com/acme/widgets",
        "https://github.com/acme/widgets.git", "https://github.com/acme/widgets.git/", "ssh://git@github.com/acme/widgets.git",
        "https://usuario:clave@github.com/acme/widgets.git", "  git@github.com:acme/widgets.git\n", "git://github.com/acme/widgets.git",
    ])
    func readsAGitHubRemote(_ remote: String) {
        let repo = GitRemoteParser.github(from: remote)
        #expect(repo == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(repo?.slug == "acme/widgets")
        #expect(repo?.url?.absoluteString == "https://github.com/acme/widgets")
    }

    // Solo github.com, y solo dueño/repo: ninguna otra remota se abre ni se consulta
    @Test(arguments: [
        "git@gitlab.com:acme/widgets.git", "https://github.com.evil.example/acme/widgets", "https://example.com/github.com/acme/widgets",
        "https://github.com/acme/widgets/tree/main", "../remote.git", "/Users/u/remote.git", "file:///Users/u/remote.git",
        "https://github.com/acme/..", "https://github.com/../widgets", "https://github.com/acme/wid gets", "git@github.com:acme",
        "https://github.com/", "",
    ])
    func rejectsAnythingElse(_ remote: String) {
        #expect(GitRemoteParser.github(from: remote) == nil)
    }

    @Test func readsTheReleases() throws {
        let releases = try #require(GitHubParser.releases(try Fixture.data("gh-release-list")))
        #expect(releases.map(\.tag) == ["v3.3.0", "v3.4.0", "v3.2.0"])
        #expect(releases.map(\.isDraft) == [false, true, false])
        // Un borrador no es una release publicada
        #expect(CIResolver.published(releases) == ["v3.3.0", "v3.2.0"])
    }

    @Test func readsTheRunsAndThePullRequests() throws {
        let runs = try #require(GitHubParser.runs(try Fixture.data("gh-run-list")))
        #expect(runs.count == 8)
        #expect(runs[1] == GitHubRun(sha: String(repeating: "b", count: 40), status: "in_progress", conclusion: ""))
        #expect(GitHubParser.count(try Fixture.data("gh-pr-list")) == 2)
        #expect(GitHubParser.count(Data("[]".utf8)) == 0)
    }

    // Un fallo de gh no es una lista vacía: es «no se sabe»
    @Test func notJSONIsUnknownAndNotEmpty() {
        let junk = Data("error connecting to api.github.com".utf8)
        #expect(GitHubParser.releases(junk) == nil)
        #expect(GitHubParser.runs(junk) == nil)
        #expect(GitHubParser.count(junk) == nil)
        #expect(GitHubParser.runs(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
    }

    @Test func ciOfACommitJoinsAllItsWorkflows() throws {
        let runs = try #require(GitHubParser.runs(try Fixture.data("gh-run-list")))
        func state(_ letter: Character) -> CIState? { CIResolver.state(of: runs, sha: String(repeating: letter, count: 40)) }
        #expect(state("a") == .passed)
        // Un flujo todavía corre, aunque otro ya haya terminado bien
        #expect(state("b") == .running)
        // Uno falló, aunque otro pasara
        #expect(state("c") == .failed)
        // Cancelado: ni bueno ni malo
        #expect(state("d") == nil)
        // Saltado y correcto, juntos, pasan
        #expect(state("e") == .passed)
        // Ningún flujo para ese commit
        #expect(state("f") == nil)
        #expect(CIResolver.state(of: [], sha: "x") == nil)
    }
}

// MARK: - El repositorio y sus filas

struct GitRowsTests {
    static func repo(
        _ name: String = "tienda", branch: String? = "main", ahead: Int? = 0, behind: Int? = 0, changed: Int = 0, untracked: Int = 0,
        hasRemote: Bool = true, unpublished: Int = 0, remote: GitHubRepo? = GitHubRepo(owner: "acme", name: "tienda"),
        tag: String? = nil, sinceTag: Int = 0, upstreamOID: String? = "u1", lastRemoteUpdate: String = "", oid: String = "h1"
    ) -> GitRepo {
        GitRepo(
            root: "/work/\(name)", commonDir: "/work/\(name)/.git",
            status: GitStatus(branch: branch, oid: oid, upstream: ahead == nil ? nil : "origin/main", ahead: ahead, behind: behind, changed: changed, untracked: untracked),
            hasRemote: hasRemote, unpublished: unpublished, remote: remote, tag: tag, sinceTag: sinceTag,
            upstreamOID: upstreamOID, lastRemoteUpdate: lastRemoteUpdate
        )
    }

    @Test func theNameIsTheFolder() {
        #expect(Self.repo("api").name == "api")
    }

    @Test func pendingPushCountsTheRightThing() {
        #expect(Self.repo(ahead: 3).pendingPush == 3)
        // Sin rama remota, los commits que ninguna remota tiene
        #expect(Self.repo(ahead: nil, unpublished: 4).pendingPush == 4)
        // Sin ninguna remota no hay nada que subir
        #expect(Self.repo(ahead: nil, hasRemote: false, unpublished: 4).pendingPush == 0)
        #expect(Self.repo(ahead: 0).pendingPush == 0)
    }

    // Un push mueve la rama remota y deja «update by push» en su reflog; un fetch o un pull, no
    @Test func aPushIsTheRemoteMovingByPush() {
        let before = Self.repo(upstreamOID: "u1", lastRemoteUpdate: "fetch origin: fast-forward")
        #expect(Self.repo(upstreamOID: "u2", lastRemoteUpdate: "update by push").pushed(since: before))
        #expect(!Self.repo(upstreamOID: "u2", lastRemoteUpdate: "fetch origin: fast-forward").pushed(since: before))
        #expect(!Self.repo(upstreamOID: "u2", lastRemoteUpdate: "pull: Fast-forward").pushed(since: before))
        // Sin cambio de la remota, no es un push nuevo
        #expect(!Self.repo(upstreamOID: "u1", lastRemoteUpdate: "update by push").pushed(since: before))
        // Otra rama: no se comparan
        #expect(!Self.repo(branch: "otra", upstreamOID: "u2", lastRemoteUpdate: "update by push").pushed(since: before))
        // La primera vez que una rama tiene remota (`push -u`)
        #expect(Self.repo(upstreamOID: "u1", lastRemoteUpdate: "update by push").pushed(since: Self.repo(upstreamOID: nil)))
        // HEAD suelto: no hay rama
        #expect(!Self.repo(branch: nil, upstreamOID: "u2", lastRemoteUpdate: "update by push").pushed(since: Self.repo(branch: nil)))
    }

    @Test func noRepositoriesAndNoGitSayWhy() {
        #expect(GitRows.content(of: [], github: [:]).notice?.title == "Ningún repositorio")
        #expect(GitRows.content(of: [], github: [:]).rows.isEmpty)
        #expect(GitRows.content(of: [Self.repo()], github: [:], gitAvailable: false).notice?.title == "No se encuentra git")
    }

    @Test func aRowTellsTheBranchAndWhatIsPending() {
        let repo = Self.repo(branch: "feature", ahead: 3, behind: 1, changed: 2, untracked: 3)
        let row = GitRows.row(for: repo, GitHubInfo(openPRs: 2))
        #expect(row.id == "/work/tienda")
        #expect(row.title == "tienda")
        #expect(row.detail == "feature ↑3 ↓1 ●5 · 2 PR")
        #expect(row.leading == .dot(.attention))
        // Un clic en el repositorio abre su página
        #expect(row.actions == [.open] && row.primaryAction == .open)
        #expect(GitRows.row(for: Self.repo(), nil).detail == "main")
        #expect(GitRows.row(for: Self.repo(branch: nil), nil).detail == "HEAD suelto")
        #expect(GitRows.row(for: Self.repo(branch: "una-rama-con-un-nombre-muy-largo"), nil).detail == "una-rama-con-un…")
        // 0 PR no se dicen
        #expect(GitRows.row(for: Self.repo(), GitHubInfo(openPRs: 0)).detail == "main")
    }

    @Test func aRepositoryWithoutGitHubHasNothingToOpen() {
        let row = GitRows.row(for: Self.repo(remote: nil), nil)
        #expect(row.actions.isEmpty)
        #expect(row.primaryAction == nil)
    }

    @Test func theDotSaysHowItIsDoing() {
        #expect(GitRows.row(for: Self.repo(), nil).leading == .dot(.ok))
        #expect(GitRows.row(for: Self.repo(ahead: 1), nil).leading == .dot(.attention))
        #expect(GitRows.row(for: Self.repo(changed: 1), nil).leading == .dot(.attention))
        #expect(GitRows.row(for: Self.repo(), GitHubInfo(ci: .failed)).leading == .dot(.alert))
        // Una remota que no es de GitHub, o ninguna, no tiene «al día»
        #expect(GitRows.row(for: Self.repo(ahead: nil, hasRemote: false, remote: nil), nil).leading == .dot(.neutral))
    }

    @Test func theRightSideShowsTheMostImportantThing() {
        func trailing(_ repo: GitRepo, _ info: GitHubInfo? = nil) -> String { GitRows.trailing(repo, info).text }
        #expect(trailing(Self.repo(), GitHubInfo(ci: .failed)) == "CI ✗")
        #expect(GitRows.trailing(Self.repo(), GitHubInfo(ci: .failed)).tone == .alert)
        #expect(trailing(Self.repo(), GitHubInfo(ci: .running)) == "CI …")
        // Una etiqueta sin release va antes que un CI que pasó
        let tagged = Self.repo(tag: "v1.4.0", sinceTag: 2)
        #expect(trailing(tagged, GitHubInfo(ci: .passed, published: ["v1.3.0"])) == "sin release")
        #expect(trailing(tagged, GitHubInfo(ci: .passed, published: ["v1.4.0"])) == "CI ✓")
        // Sin lo que dice gh, la etiqueta y los commits desde ella
        #expect(trailing(tagged) == "v1.4.0 +2")
        #expect(trailing(Self.repo(tag: "v1.4.0")) == "v1.4.0")
        #expect(trailing(Self.repo()) == "")
        // gh no contestó: no se dice «sin release»
        #expect(!GitRows.isUnreleased(tagged, GitHubInfo(published: nil)))
        #expect(!GitRows.isUnreleased(tagged, nil))
    }

    @Test func theMostUrgentComeFirstAndOnlyThreeFit() {
        let repos = ["delta", "alfa", "bravo", "charlie", "echo"].map { Self.repo($0) } + [Self.repo("zulu", ahead: 2)]
        // zulu tiene commits sin subir; delta, un CI roto
        let content = GitRows.content(of: repos, github: ["/work/delta": GitHubInfo(ci: .failed)])
        #expect(content.rows.map(\.title) == ["delta", "zulu", "alfa"])
        #expect(content.summary == "3 de 6")
        #expect(GitRows.content(of: [Self.repo()], github: [:]).summary == "1 repo")
        #expect(GitRows.content(of: [Self.repo(), Self.repo("api")], github: [:]).summary == "2 repos")
        #expect(GitRows.content(of: [Self.repo("b"), Self.repo("a")], github: [:]).rows.map(\.title) == ["a", "b"])
    }
}

// MARK: - Cuándo avisa

struct GitNoticeDetectorTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = GitNoticeSettings()

    private func repo(ahead: Int = 0, changed: Int = 0, tag: String? = nil) -> GitRepo {
        GitRowsTests.repo(ahead: ahead, changed: changed, tag: tag)
    }

    @Test func commitsNotPushedForAWhileAreAnnouncedOncePerStreak() {
        var detector = GitNoticeDetector()
        #expect(detector.observe(repo(ahead: 3), at: start, settings: settings) == nil)
        // Aún no han pasado 30 min
        #expect(detector.observe(repo(ahead: 3), at: start + 29 * 60, settings: settings) == nil)
        let notice = detector.observe(repo(ahead: 4), at: start + 31 * 60, settings: settings)
        #expect(notice == GitNotice(repo: "tienda", kind: .unpushed(commits: 4)))
        // Una vez
        #expect(detector.observe(repo(ahead: 4), at: start + 40 * 60, settings: settings) == nil)
        #expect(detector.nextDeadline(settings: settings) == nil)
        // Al subirlos se acaba la racha, y la siguiente vuelve a contar desde cero
        #expect(detector.observe(repo(ahead: 0), at: start + 50 * 60, settings: settings) == nil)
        #expect(detector.observe(repo(ahead: 1), at: start + 60 * 60, settings: settings) == nil)
        #expect(detector.observe(repo(ahead: 1), at: start + 91 * 60, settings: settings) != nil)
    }

    @Test func theDeadlineIsWhenTheThresholdPasses() {
        var detector = GitNoticeDetector()
        #expect(detector.nextDeadline(settings: settings) == nil)
        _ = detector.observe(repo(ahead: 1), at: start, settings: settings)
        #expect(detector.nextDeadline(settings: settings) == start + 30 * 60)
        var shorter = settings
        shorter.unpushedAfter = 10 * 60
        #expect(detector.nextDeadline(settings: shorter) == start + 10 * 60)
        // Apagado, no hay hora
        shorter.unpushed = false
        #expect(detector.nextDeadline(settings: shorter) == nil)
    }

    @Test func aSwitchedOffNoticeNeverComes() {
        var detector = GitNoticeDetector()
        var off = settings
        off.unpushed = false
        _ = detector.observe(repo(ahead: 1), at: start, settings: off)
        #expect(detector.observe(repo(ahead: 1), at: start + 3600, settings: off) == nil)
        // Al volver a encenderlo, con la racha vieja, avisa
        #expect(detector.observe(repo(ahead: 1), at: start + 3601, settings: settings) != nil)
    }

    // `Stop` llega con cada turno de Claude: solo avisa la primera vez, hasta que el repositorio vuelve a estar limpio
    @Test func uncommittedChangesAreAnnouncedOnceUntilClean() {
        var detector = GitNoticeDetector()
        #expect(detector.sessionFinished(in: repo(), settings: settings) == nil)
        #expect(detector.sessionFinished(in: repo(changed: 2), settings: settings) == GitNotice(repo: "tienda", kind: .uncommitted(files: 2)))
        #expect(detector.sessionFinished(in: repo(changed: 3), settings: settings) == nil)
        // Limpio otra vez, medido por la vigilancia o al terminar otra sesión
        #expect(detector.observe(repo(), at: start, settings: settings) == nil)
        #expect(detector.sessionFinished(in: repo(changed: 1), settings: settings) != nil)
        var off = settings
        off.uncommitted = false
        var other = GitNoticeDetector()
        #expect(other.sessionFinished(in: repo(changed: 1), settings: off) == nil)
    }

    @Test func anUnreleasedTagIsAnnouncedOncePerTagAndOnlyIfGitHubAnswered() {
        var detector = GitNoticeDetector()
        let tagged = repo(tag: "v1.4.0")
        // gh no contestó: no se sabe
        #expect(detector.releaseChecked(in: tagged, published: nil, settings: settings) == nil)
        #expect(detector.releaseChecked(in: tagged, published: ["v1.4.0"], settings: settings) == nil)
        #expect(detector.releaseChecked(in: repo(), published: [], settings: settings) == nil)
        #expect(detector.releaseChecked(in: tagged, published: ["v1.3.0"], settings: settings) == GitNotice(repo: "tienda", kind: .unreleased(tag: "v1.4.0")))
        #expect(detector.releaseChecked(in: tagged, published: ["v1.3.0"], settings: settings) == nil)
        // Otra etiqueta
        #expect(detector.releaseChecked(in: repo(tag: "v1.5.0"), published: ["v1.3.0"], settings: settings) != nil)
    }

    @Test func theCIOfACommitIsAnnouncedOnceWhenItEnds() {
        var detector = GitNoticeDetector()
        let repo = repo()
        #expect(detector.ciFinished(in: repo, sha: "h1", state: .running, settings: settings) == nil)
        #expect(detector.ciFinished(in: repo, sha: "h1", state: .failed, settings: settings) == GitNotice(repo: "tienda", kind: .ci(.failed)))
        #expect(detector.ciFinished(in: repo, sha: "h1", state: .failed, settings: settings) == nil)
        #expect(detector.ciFinished(in: repo, sha: "h2", state: .passed, settings: settings) == GitNotice(repo: "tienda", kind: .ci(.passed)))
        var off = settings
        off.ci = false
        #expect(detector.ciFinished(in: repo, sha: "h3", state: .passed, settings: off) == nil)
    }

    @Test func forgettingARepositoryLetsItAnnounceAgain() {
        var detector = GitNoticeDetector()
        _ = detector.observe(repo(ahead: 1), at: start, settings: settings)
        _ = detector.sessionFinished(in: repo(changed: 1), settings: settings)
        detector.forget("/work/tienda")
        #expect(detector.nextDeadline(settings: settings) == nil)
        #expect(detector.sessionFinished(in: repo(changed: 1), settings: settings) != nil)
    }
}

// MARK: - Lo que se ve en la isla cerrada

struct GitNoticeDisplayTests {
    @Test func eachNoticeSaysWhatHappened() {
        func title(_ kind: GitNotice.Kind) -> String { GitNotice(repo: "tienda", kind: kind).title }
        #expect(title(.unpushed(commits: 1)) == "1 commit sin push")
        #expect(title(.unpushed(commits: 3)) == "3 commits sin push")
        #expect(title(.uncommitted(files: 1)) == "1 archivo sin commit")
        #expect(title(.uncommitted(files: 4)) == "4 archivos sin commit")
        #expect(title(.unreleased(tag: "v3.4.0")) == "v3.4.0 sin release")
        #expect(title(.ci(.passed)) == "CI correcto")
        #expect(title(.ci(.failed)) == "CI falló")
        #expect(GitNotice(repo: "tienda", kind: .unpushed(commits: 3)).notice.subtitle == "tienda")
    }

    @Test func aFailedCIIsAnErrorThatStaysLonger() {
        let failed = IslandPeek.notice(GitNotice(repo: "r", kind: .ci(.failed)).notice)
        let passed = IslandPeek.notice(GitNotice(repo: "r", kind: .ci(.passed)).notice)
        let unpushed = IslandPeek.notice(GitNotice(repo: "r", kind: .unpushed(commits: 2)).notice)
        #expect(failed.duration == .seconds(8))
        #expect(passed.duration == .seconds(5))
        #expect(unpushed.duration == .seconds(5))
        #expect(failed.widensWings)
        #expect(GitNotice(repo: "r", kind: .ci(.failed)).notice.tone == .error)
        #expect(GitNotice(repo: "r", kind: .ci(.passed)).notice.tone == .ok)
    }

    // Una pregunta de Claude, el Pomodoro, los avisos de Git, la batería y la canción, por ese orden
    @Test func priorityPutsGitBetweenThePomodoroAndTheBattery() {
        let notice = IslandPeek.notice(GitNotice(repo: "r", kind: .unpushed(commits: 1)).notice)
        let pomodoro = IslandPeek.pomodoro(PomodoroPeek(phase: .shortBreak, kind: .started(minutes: 5)))
        let battery = IslandPeek.battery(.low, level: 15)
        let ask = IslandPeek.claude(ClaudePeek(kind: .asks, folder: "x", detail: ""))
        let finished = IslandPeek.claude(ClaudePeek(kind: .finished, folder: "x", detail: ""))
        #expect(ask.priority > pomodoro.priority)
        #expect(pomodoro.priority > notice.priority)
        #expect(notice.priority > battery.priority)
        #expect(notice.priority > finished.priority)
        #expect(battery.priority > IslandPeek.track.priority)
    }

    // El log no lleva el repositorio ni la etiqueta
    @Test func theLogSummaryHasNoNames() {
        let peek = IslandPeek.notice(GitNotice(repo: "secreto", kind: .unreleased(tag: "v9.9.9")).notice)
        #expect(!peek.summary.contains("secreto"))
        #expect(!peek.summary.contains("9.9.9"))
    }
}
