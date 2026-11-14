import Foundation

// Lógica pura del módulo Git (fase 40): de la salida de `git` y `gh` al estado de cada repositorio, a las filas del módulo y
// a cuándo avisa la isla cerrada. Solo informa: la app nunca hace commit, push, fetch ni crea etiquetas.

// MARK: - git

/// Lo que dice `git status --porcelain=v2 --branch`
struct GitStatus: Equatable, Sendable {
    /// nil con HEAD suelto (detached)
    var branch: String?
    /// El commit actual; nil en un repositorio sin commits
    var oid: String?
    /// La rama remota que sigue («origin/main»); nil si no sigue ninguna
    var upstream: String?
    /// Los commits que tienes y la rama remota no, y los que tiene y tú no. nil sin rama remota
    var ahead: Int?
    var behind: Int?
    /// Archivos con cambios sin commit, sin contar los nuevos que git no sigue
    var changed = 0
    var untracked = 0

    /// Lo que cambió sin llegar a un commit
    var dirty: Int { changed + untracked }
}

// Una línea por dato. Las cabeceras empiezan por «# » (`branch.oid` es `(initial)` en un repositorio sin commits y
// `branch.head` es `(detached)` con HEAD suelto; `branch.upstream` y `branch.ab` solo salen si la rama sigue a otra). Después,
// una línea por archivo: `1` y `2` son cambios ordinarios y renombrados, `u` conflictos, `?` archivos sin seguimiento.
enum GitStatusParser {
    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": status.oid = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head": status.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    let numbers = parts[1].split(separator: " ").compactMap { Int($0.dropFirst()) }
                    if numbers.count == 2 { (status.ahead, status.behind) = (numbers[0], numbers[1]) }
                default: break
                }
            } else if let kind = line.first, line.dropFirst().first == " " {
                switch kind {
                case "1", "2", "u": status.changed += 1
                case "?": status.untracked += 1
                default: break
                }
            }
        }
        return status
    }
}

/// Dónde está un repositorio: su carpeta y su `.git` común (en un worktree, el de la carpeta principal: ahí viven las ramas, las
/// etiquetas y las remotas)
struct GitLocation: Equatable, Sendable {
    var root: String
    var commonDir: String
}

enum GitRevParse {
    /// La salida de `git rev-parse --path-format=absolute --show-toplevel --git-common-dir`: dos rutas absolutas
    static func parse(_ output: String) -> GitLocation? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 2, lines.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return GitLocation(root: lines[0], commonDir: lines[1])
    }
}

/// Un repositorio de GitHub: de ahí sale la página que abre un clic y el `-R` de `gh`
struct GitHubRepo: Equatable, Sendable {
    var owner: String
    var name: String

    var slug: String { "\(owner)/\(name)" }
    /// Siempre armada aquí, nunca copiada de la remota
    var url: URL? { URL(string: "https://github.com/\(owner)/\(name)") }
}

enum GitRemoteParser {
    /// `git@github.com:dueño/repo.git`, `ssh://git@github.com/dueño/repo`, `https://github.com/dueño/repo.git`. Solo
    /// github.com: ninguna otra remota se abre ni se consulta con `gh`
    static func github(from remote: String) -> GitHubRepo? {
        var rest = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = rest.range(of: "://") {
            rest = String(rest[range.upperBound...])
        } else if let colon = rest.firstIndex(of: ":"), colon < (rest.firstIndex(of: "/") ?? rest.endIndex) {
            // Forma scp: [usuario@]servidor:dueño/repo
            rest.replaceSubrange(colon...colon, with: "/")
        }
        // Un usuario delante del servidor: `git@`, o `usuario:clave@` en https
        if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) {
            rest = String(rest[rest.index(after: at)...])
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "github.com" else { return nil }
        var name = parts[2]
        if name.hasSuffix(".git") { name.removeLast(4) }
        // Más segmentos que dueño/repo no es una remota de git
        guard parts.count == 3, isValid(parts[1]), isValid(name) else { return nil }
        return GitHubRepo(owner: parts[1], name: name)
    }

    private static func isValid(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".."
            && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }
}

/// Un repositorio en un momento. Se rehace con cada medida
struct GitRepo: Equatable, Sendable, Identifiable {
    var root: String
    var commonDir: String
    var status: GitStatus
    /// Hay alguna remota
    var hasRemote: Bool
    /// Los commits que ninguna remota tiene, cuando la rama no sigue a ninguna
    var unpublished: Int
    var remote: GitHubRepo?
    /// La última etiqueta y los commits desde ella
    var tag: String?
    var sinceTag: Int
    /// Adónde apunta la rama remota que sigue, y lo que dice su reflog («update by push» tras un push)
    var upstreamOID: String?
    var lastRemoteUpdate: String
    /// Cómo se llama esa rama en la remota («main» para `origin/main`); nil si no sigue ninguna
    var upstreamBranch: String?

    var id: String { root }
    var name: String { URL(filePath: root).lastPathComponent }

    /// Commits que no se han subido. Sin remota, nada se puede subir
    var pendingPush: Int { hasRemote ? (status.ahead ?? unpublished) : 0 }

    /// La remota se movió porque se hizo un push (y no un fetch o un pull). Compara con la medida anterior de la misma rama
    func pushed(since previous: GitRepo) -> Bool {
        status.branch != nil && status.branch == previous.status.branch
            && upstreamOID != nil && upstreamOID != previous.upstreamOID && lastRemoteUpdate.hasPrefix("update by push")
    }
}

// MARK: - gh

enum CIState: Equatable, Sendable {
    case running, passed, failed
}

struct GitHubRelease: Equatable, Sendable {
    var tag: String
    var isDraft: Bool
}

struct GitHubRun: Equatable, Sendable {
    var sha: String
    var status: String
    var conclusion: String
}

/// Lo que se sabe de un repositorio por `gh`. Cada campo es nil mientras no se haya podido medir: un fallo de `gh` (sin red,
/// sin sesión) es «no se sabe», nunca «sin release» ni «CI fallido»
struct GitHubInfo: Equatable, Sendable {
    var ci: CIState?
    /// Las etiquetas con release publicada (los borradores no cuentan)
    var published: Set<String>?
    var openPRs: Int?
}

enum GitHubParser {
    /// `gh release list --json tagName,isDraft`
    static func releases(_ data: Data) -> [GitHubRelease]? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            (item["tagName"] as? String).map { GitHubRelease(tag: $0, isDraft: item["isDraft"] as? Bool ?? false) }
        }
    }

    /// `gh run list --json headSha,status,conclusion`
    static func runs(_ data: Data) -> [GitHubRun]? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let sha = item["headSha"] as? String, let status = item["status"] as? String else { return nil }
            return GitHubRun(sha: sha, status: status, conclusion: item["conclusion"] as? String ?? "")
        }
    }

    /// `gh pr list --json number`: cuántos hay
    static func count(_ data: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count
    }
}

enum CIResolver {
    static let failures: Set<String> = ["failure", "timed_out", "startup_failure"]
    static let successes: Set<String> = ["success", "skipped", "neutral"]

    /// Cómo va el CI de un commit, con todos sus flujos de trabajo juntos. nil si ninguno se ha visto todavía, o si el resultado
    /// no es ni bueno ni malo (cancelado, a la espera de aprobación)
    static func state(of runs: [GitHubRun], sha: String) -> CIState? {
        let ours = runs.filter { $0.sha == sha }
        guard !ours.isEmpty else { return nil }
        if ours.contains(where: { $0.status != "completed" }) { return .running }
        if ours.contains(where: { failures.contains($0.conclusion) }) { return .failed }
        return ours.allSatisfy { successes.contains($0.conclusion) } ? .passed : nil
    }

    static func published(_ releases: [GitHubRelease]) -> Set<String> {
        Set(releases.filter { !$0.isDraft }.map(\.tag))
    }
}

// MARK: - Filas del módulo

enum GitRows {
    /// Como mucho tantas filas como caben (`ModuleRowLayout.maxRows`)
    static let visibleRows = ModuleRowLayout.maxRows

    /// Los que tienen algo pendiente van primero: un CI fallido, y después los cambios o commits sin subir
    private static func rank(_ repo: GitRepo, _ info: GitHubInfo?) -> Int {
        if info?.ci == .failed { return 0 }
        return needsAttention(repo, info) ? 1 : 2
    }

    private static func needsAttention(_ repo: GitRepo, _ info: GitHubInfo?) -> Bool {
        repo.pendingPush > 0 || repo.status.dirty > 0 || isUnreleased(repo, info)
    }

    /// La última etiqueta no está entre las releases publicadas (solo si `gh` ya lo dijo)
    static func isUnreleased(_ repo: GitRepo, _ info: GitHubInfo?) -> Bool {
        guard let tag = repo.tag, let published = info?.published else { return false }
        return !published.contains(tag)
    }

    static func content(of repos: [GitRepo], github: [String: GitHubInfo], gitAvailable: Bool = true) -> ModuleRowsContent {
        guard gitAvailable else {
            return ModuleRowsContent(
                summary: "", rows: [], notice: .init(title: "No se encuentra git", subtitle: "Instala las herramientas de línea de comandos.")
            )
        }
        guard !repos.isEmpty else {
            return ModuleRowsContent(
                summary: "", rows: [],
                notice: .init(title: "Ningún repositorio", subtitle: "Abre una sesión de Claude Code o añade una carpeta en Ajustes.")
            )
        }
        let sorted = repos.sorted { a, b in
            let (ra, rb) = (rank(a, github[a.id]), rank(b, github[b.id]))
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let rows = sorted.prefix(visibleRows).map { row(for: $0, github[$0.id]) }
        let summary = repos.count > visibleRows ? "\(visibleRows) de \(repos.count)" : repos.count == 1 ? "1 repo" : "\(repos.count) repos"
        return ModuleRowsContent(summary: summary, rows: rows, notice: nil)
    }

    static func row(for repo: GitRepo, _ info: GitHubInfo?) -> ModuleRow {
        let hasPage = repo.remote != nil
        return ModuleRow(
            id: repo.id, leading: .dot(tone(repo, info)), title: repo.name, detail: detail(repo, info), trailing: trailing(repo, info).text,
            tone: trailing(repo, info).tone, actions: hasPage ? [.open] : [], primaryAction: hasPage ? .open : nil
        )
    }

    private static func tone(_ repo: GitRepo, _ info: GitHubInfo?) -> RowTone {
        if info?.ci == .failed { return .alert }
        if needsAttention(repo, info) { return .attention }
        return repo.hasRemote ? .ok : .neutral
    }

    /// «main ↑3 ↓1 ●2 · 2 PR»: la rama, los commits por subir y por bajar, los archivos con cambios y los PR abiertos
    static func detail(_ repo: GitRepo, _ info: GitHubInfo?) -> String {
        var parts = [branchName(repo.status.branch)]
        if repo.pendingPush > 0 { parts.append("↑\(repo.pendingPush)") }
        if let behind = repo.status.behind, behind > 0 { parts.append("↓\(behind)") }
        if repo.status.dirty > 0 { parts.append("●\(repo.status.dirty)") }
        var text = parts.joined(separator: " ")
        if let prs = info?.openPRs, prs > 0 { text += " · \(prs) PR" }
        return text
    }

    private static func branchName(_ branch: String?) -> String {
        guard let branch else { return "HEAD suelto" }
        return branch.count > 16 ? String(branch.prefix(15)) + "…" : branch
    }

    /// Lo que va a la derecha: el CI si falló o corre, una etiqueta sin publicar, el CI que pasó, o la última etiqueta
    static func trailing(_ repo: GitRepo, _ info: GitHubInfo?) -> (text: String, tone: RowTone) {
        switch info?.ci {
        case .failed: return ("CI ✗", .alert)
        case .running: return ("CI …", .active)
        default: break
        }
        if isUnreleased(repo, info) { return ("sin release", .attention) }
        if info?.ci == .passed { return ("CI ✓", .ok) }
        guard let tag = repo.tag else { return ("", .neutral) }
        return (repo.sinceTag > 0 ? "\(tag) +\(repo.sinceTag)" : tag, .neutral)
    }
}

// MARK: - Avisos de la isla cerrada

/// Lo que se avisa. Cada uno, una vez por estado
struct GitNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Llevan más de un rato sin subirse
        case unpushed(commits: Int)
        /// Una sesión de Claude Code terminó y quedaron cambios
        case uncommitted(files: Int)
        /// La última etiqueta no tiene release en GitHub
        case unreleased(tag: String)
        /// El CI del último push terminó
        case ci(CIState)
    }

    var repo: String
    var kind: Kind

    var title: String {
        switch kind {
        case .unpushed(let commits): commits == 1 ? "1 commit sin push" : "\(commits) commits sin push"
        case .uncommitted(let files): files == 1 ? "1 archivo sin commit" : "\(files) archivos sin commit"
        case .unreleased(let tag): "\(tag) sin release"
        case .ci(let state): state == .failed ? "CI falló" : "CI correcto"
        }
    }

    var notice: IslandNotice {
        switch kind {
        case .unpushed: IslandNotice(symbol: "arrow.up.circle.fill", tone: .warning, title: title, subtitle: repo)
        case .uncommitted: IslandNotice(symbol: "pencil.circle.fill", tone: .warning, title: title, subtitle: repo)
        case .unreleased: IslandNotice(symbol: "tag.fill", tone: .warning, title: title, subtitle: repo)
        case .ci(let state):
            IslandNotice(
                symbol: state == .failed ? "xmark.octagon.fill" : "checkmark.circle.fill", tone: state == .failed ? .error : .ok,
                title: title, subtitle: repo, isUrgent: state == .failed
            )
        }
    }
}

/// Qué avisos están encendidos y desde cuándo
struct GitNoticeSettings: Equatable, Sendable {
    var unpushed = true
    /// Cuánto llevan los commits sin subirse antes de avisar
    var unpushedAfter: TimeInterval = 30 * 60
    var uncommitted = true
    var unreleased = true
    var ci = true
}

// Decide cuándo avisa cada cosa. Cada aviso sale una vez por estado: los commits sin push, una vez por racha (hasta que no
// quede ninguno); los cambios sin commit, una vez hasta que el repositorio vuelva a estar limpio (`Stop` llega con cada turno
// de Claude); una etiqueta sin release, una vez por etiqueta; y el CI, una vez por commit. Las fechas llegan de fuera.
struct GitNoticeDetector: Sendable {
    /// Cuántas etiquetas y commits recuerda: nadie las usa ya cuando pasan de tantas
    static let maxRemembered = 200

    private var pendingSince: [String: Date] = [:]
    private var unpushedNotified: Set<String> = []
    private var uncommittedNotified: Set<String> = []
    private var unreleasedNotified: Set<String> = []
    private var ciNotified: Set<String> = []

    /// Con cada medida nueva: lleva la cuenta de los commits sin subir y avisa cuando pasa el tiempo
    mutating func observe(_ repo: GitRepo, at now: Date, settings: GitNoticeSettings) -> GitNotice? {
        if repo.status.dirty == 0 { uncommittedNotified.remove(repo.id) }
        guard repo.pendingPush > 0 else {
            pendingSince[repo.id] = nil
            unpushedNotified.remove(repo.id)
            return nil
        }
        let since = pendingSince[repo.id] ?? now
        pendingSince[repo.id] = since
        guard settings.unpushed, !unpushedNotified.contains(repo.id), now.timeIntervalSince(since) >= settings.unpushedAfter else { return nil }
        unpushedNotified.insert(repo.id)
        return GitNotice(repo: repo.name, kind: .unpushed(commits: repo.pendingPush))
    }

    /// Cuándo hay que volver a mirar para que el aviso de los commits sin subir salga a su hora; nil si no hay ninguno pendiente
    func nextDeadline(settings: GitNoticeSettings) -> Date? {
        guard settings.unpushed else { return nil }
        return pendingSince.filter { !unpushedNotified.contains($0.key) }.values.min().map { $0.addingTimeInterval(settings.unpushedAfter) }
    }

    /// Una sesión de Claude Code terminó en este repositorio, ya medido
    mutating func sessionFinished(in repo: GitRepo, settings: GitNoticeSettings) -> GitNotice? {
        guard repo.status.dirty > 0 else {
            uncommittedNotified.remove(repo.id)
            return nil
        }
        guard settings.uncommitted, uncommittedNotified.insert(repo.id).inserted else { return nil }
        return GitNotice(repo: repo.name, kind: .uncommitted(files: repo.status.dirty))
    }

    /// `published` son las etiquetas con release; nil si `gh` no contestó, y entonces no se avisa
    mutating func releaseChecked(in repo: GitRepo, published: Set<String>?, settings: GitNoticeSettings) -> GitNotice? {
        guard settings.unreleased, let tag = repo.tag, let published, !published.contains(tag) else { return nil }
        trim(&unreleasedNotified)
        guard unreleasedNotified.insert("\(repo.id)\t\(tag)").inserted else { return nil }
        return GitNotice(repo: repo.name, kind: .unreleased(tag: tag))
    }

    mutating func ciFinished(in repo: GitRepo, sha: String, state: CIState, settings: GitNoticeSettings) -> GitNotice? {
        guard settings.ci, state != .running else { return nil }
        trim(&ciNotified)
        guard ciNotified.insert("\(repo.id)\t\(sha)").inserted else { return nil }
        return GitNotice(repo: repo.name, kind: .ci(state))
    }

    /// El repositorio ya no se vigila
    mutating func forget(_ id: String) {
        pendingSince[id] = nil
        unpushedNotified.remove(id)
        uncommittedNotified.remove(id)
    }

    private func trim(_ set: inout Set<String>) {
        if set.count >= Self.maxRemembered { set.removeAll() }
    }
}
