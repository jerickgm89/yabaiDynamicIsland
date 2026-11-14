import AppKit
import Foundation

// Los avisos de la terminal que llegan de `yb` (fase 41): decide si se enseñan, de qué app vienen y cómo se dicen. Lo que llega es de
// cualquier proceso (la notificación es de todo el sistema): se valida en `AvisoMessage.terminalNotice`, y lo único que hace un
// aviso es aparecer en la isla; un clic en él solo lleva a una app que ya está abierta.

/// Las terminales y editores que se conocen por `$TERM_PROGRAM`: cómo se llaman y su identificador, para ir a ellos
enum TerminalApp {
    private static let known: [String: (name: String, bundleID: String)] = [
        "ghostty": ("Ghostty", "com.mitchellh.ghostty"),
        "WarpTerminal": ("Warp", "dev.warp.Warp-Stable"),
        "Apple_Terminal": ("Terminal", "com.apple.Terminal"),
        "iTerm.app": ("iTerm", "com.googlecode.iterm2"),
        "vscode": ("VS Code", "com.microsoft.VSCode"),
        "WezTerm": ("WezTerm", "com.github.wez.wezterm"),
        "Hyper": ("Hyper", "co.zeit.hyper"),
        "kitty": ("kitty", "net.kovidgoyal.kitty"),
        "alacritty": ("Alacritty", "org.alacritty"),
    ]

    /// «ghostty» → «Ghostty». Si no se conoce, el nombre tal cual; vacío si no se sabe
    static func displayName(forProgram program: String) -> String {
        known[program]?.name ?? program
    }

    static func bundleID(forProgram program: String) -> String? {
        known[program]?.bundleID
    }
}

enum TerminalNoticeText {
    /// «npm terminó» o «npm falló»; un aviso a mano, su título
    static func title(_ notice: TerminalNotice) -> String {
        switch notice.source {
        case .command(let name, let code, _): code == 0 ? "\(name) terminó" : "\(name) falló"
        case .custom(let title, _, _): title
        }
    }

    /// Lo que cabe bajo el título en el ala de la isla cerrada, que es estrecha: lo que tardó, y el código si falló
    static func subtitle(_ notice: TerminalNotice) -> String {
        switch notice.source {
        case .command(_, let code, let seconds):
            let took = ClaudePeek.spoken(TimeInterval(seconds))
            return code == 0 ? took : "código \(code) · \(took)"
        case .custom(_, let detail, _):
            return detail
        }
    }

    /// Para la fila del módulo, que es más ancha: el subtítulo y la terminal de donde viene
    static func detail(_ notice: TerminalNotice) -> String {
        let terminal = TerminalApp.displayName(forProgram: notice.terminal)
        return [subtitle(notice), terminal].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func islandNotice(_ notice: TerminalNotice) -> IslandNotice {
        let (symbol, tone): (String, IslandNotice.Tone) = switch notice.status {
        case .ok: ("checkmark.circle.fill", .ok)
        case .error: ("xmark.octagon.fill", .error)
        case .info: ("terminal.fill", .info)
        }
        return IslandNotice(symbol: symbol, tone: tone, title: title(notice), subtitle: subtitle(notice), isUrgent: notice.status == .error)
    }

    static func rowTone(_ status: TerminalNotice.Status) -> RowTone {
        switch status {
        case .ok: .ok
        case .error: .alert
        case .info: .active
        }
    }
}

@MainActor
final class TerminalNotices {
    /// Lo que sale de un aviso aceptado
    struct Result: Equatable {
        var entry: NoticeEntry
        var notice: IslandNotice
        /// Un comando que falló: Desarrollador se queda con el punto rojo
        var failed: Bool
        /// La terminal está delante y no se pidió avisar entonces: va al módulo Avisos, no a la isla
        var suppressPeek: Bool
    }

    private let settings: AppSettings
    private let frontmost: @MainActor () -> String?
    private let originOf: @MainActor (Int32) -> String?

    init(
        settings: AppSettings,
        frontmost: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        originOf: @escaping @MainActor (Int32) -> String? = TerminalNotices.appBundleID(ofProcess:)
    ) {
        self.settings = settings
        self.frontmost = frontmost
        self.originOf = originOf
    }

    /// nil si no es un aviso de la terminal, si están apagados o si el comando duró menos del mínimo de Ajustes
    func handle(_ message: AvisoMessage, now: Date = Date()) -> Result? {
        guard settings.terminalNotices, let notice = message.terminalNotice else { return nil }
        var isCommand = false
        if case .command(_, _, let seconds) = notice.source {
            guard seconds >= settings.terminalMinSeconds else { return nil }
            isCommand = true
        }
        // La app que se dijo con `--app`, la de la que cuelga el proceso que lo mandó, o la que dice `$TERM_PROGRAM`
        let bundleID = notice.appBundleID ?? notice.pid.flatMap(originOf) ?? TerminalApp.bundleID(forProgram: notice.terminal)
        let entry = NoticeEntry(
            date: now, tone: TerminalNoticeText.rowTone(notice.status), title: TerminalNoticeText.title(notice),
            detail: TerminalNoticeText.detail(notice), origin: .terminal(bundleID: bundleID)
        )
        // Con la terminal delante ya ves el comando terminar. Un `yb aviso` a mano es una petición: ese sí se enseña
        let inFront = isCommand && !settings.terminalWhenFrontmost && bundleID != nil && frontmost() == bundleID
        // Un comando que falló, o un `yb aviso --error`: Desarrollador se queda con el punto rojo
        return Result(entry: entry, notice: TerminalNoticeText.islandNotice(notice), failed: notice.status == .error, suppressPeek: inFront)
    }

    // MARK: - Origen y clic

    /// La app normal de la que cuelga un proceso (normalmente la shell): Ghostty, VS Code, Terminal…
    static func appBundleID(ofProcess pid: Int32) -> String? {
        guard let app = ProcessAncestry.firstApp(
            from: pid, parent: ProcessProbe.parentPID(of:),
            isApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
        ) else { return nil }
        return NSRunningApplication(processIdentifier: app)?.bundleIdentifier
    }

    /// Lleva delante una app que ya está abierta. Nunca abre una que no lo esté: lo que dice un aviso no lanza programas. Devuelve
    /// si la encontró
    @discardableResult
    static func activate(bundleID: String) -> Bool {
        guard BundleIdentifier.isValid(bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.activationPolicy == .regular }),
              let url = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }
}
