import Foundation

// Los avisos de la terminal (fase 41): lo que `yb aviso` y los hooks de zsh le cuentan a YabaiBar, cómo se leen los argumentos de
// `yb` y el script que `yb shell-init zsh` imprime. Lo compilan la app y el ayudante `yb`, así que no depende de AppKit.
//
// Igual que con los hooks de Claude Code, el aviso viaja por una notificación distribuida que cualquier proceso puede mandar:
// la app valida lo que llega (`AvisoMessage.terminalNotice`), y lo que dice un aviso solo cambia lo que enseña la isla.

/// Un aviso de la terminal: un comando largo que terminó, o lo que alguien le pidió a `yb aviso`
struct TerminalNotice: Equatable, Sendable {
    enum Status: String, Sendable {
        case ok, error, info
    }

    enum Source: Equatable, Sendable {
        /// Un comando largo que terminó: el programa (nunca la línea entera, que puede llevar claves), su código de salida y los
        /// segundos que tardó
        case command(name: String, exitCode: Int, seconds: Int)
        /// `yb aviso`: el título y el detalle que se dieron
        case custom(title: String, detail: String, status: Status)
    }

    var source: Source
    /// `$TERM_PROGRAM` de quien lo manda («ghostty», «vscode»…); vacío si no se sabe
    var terminal = ""
    /// El proceso padre de `yb`, normalmente la shell: la app sube por sus padres hasta la app en que corre
    var pid: Int32?
    /// Una app concreta, dicha con `--app`. Solo se activa si ya está abierta
    var appBundleID: String?

    var status: Status {
        switch source {
        case .command(_, let code, _): code == 0 ? .ok : .error
        case .custom(_, _, let status): status
        }
    }
}

extension AvisoMessage {
    init(_ notice: TerminalNotice) {
        var fields: [String: String] = ["terminal": notice.terminal]
        switch notice.source {
        case .command(let name, let code, let seconds):
            fields["event"] = "command"
            fields["name"] = name
            fields["exit"] = String(code)
            fields["seconds"] = String(seconds)
        case .custom(let title, let detail, let status):
            fields["event"] = "custom"
            fields["title"] = title
            fields["detail"] = detail
            fields["status"] = status.rawValue
        }
        if let pid = notice.pid { fields["pid"] = String(pid) }
        if let app = notice.appBundleID { fields["app"] = app }
        self.init(kind: .terminal, fields: fields)
    }

    /// El aviso de la terminal que lleva, si lo lleva y se entiende. Cualquier proceso puede mandar uno: se limpia y se acota todo
    var terminalNotice: TerminalNotice? {
        guard kind == .terminal else { return nil }
        func clean(_ key: String, limit: Int) -> String { ClaudeHookText.clean(fields[key] ?? "", limit: limit) }
        let source: TerminalNotice.Source
        switch fields["event"] {
        case "command":
            let name = clean("name", limit: 40)
            // Un código de salida de shell va de 0 a 255 (con una señal, 128 más su número); lo que se salga de ahí no es nuestro
            guard !name.isEmpty, let code = fields["exit"].flatMap({ Int($0) }), (-1...512).contains(code),
                  let seconds = fields["seconds"].flatMap({ Int($0) }), (0...7 * 24 * 3600).contains(seconds) else { return nil }
            source = .command(name: name, exitCode: code, seconds: seconds)
        case "custom":
            let title = clean("title", limit: 80)
            guard !title.isEmpty else { return nil }
            source = .custom(
                title: title, detail: clean("detail", limit: 120),
                status: fields["status"].flatMap(TerminalNotice.Status.init(rawValue:)) ?? .info
            )
        default:
            return nil
        }
        return TerminalNotice(
            source: source, terminal: clean("terminal", limit: 40), pid: fields["pid"].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil },
            appBundleID: fields["app"].flatMap { BundleIdentifier.isValid($0) ? $0 : nil }
        )
    }
}

enum BundleIdentifier {
    private static let alphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let allowed = alphanumerics.union(CharacterSet(charactersIn: ".-"))

    /// Letras y cifras ASCII, puntos y guiones, y empezando por una letra o cifra: lo que lleva un identificador de app de verdad
    static func isValid(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, alphanumerics.contains(first), text.count <= 100 else { return false }
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Argumentos de `yb`

enum YbArguments {
    static let usage = """
        Uso:
          yb aviso "título" ["detalle"] [--ok | --error | --info] [--app <bundle id>]
          yb shell-init zsh
        Para avisar al terminar un comando largo, añade a ~/.zshrc:  eval "$(yb shell-init zsh)"
        """

    enum Failure: Error, Equatable {
        case missingTitle
        case tooManyWords
        case unknownOption(String)
        case missingValue(String)
        case invalidBundleID(String)
        case invalidNumber(String)

        var message: String {
            switch self {
            case .missingTitle: "Falta el título del aviso."
            case .tooManyWords: "Solo van el título y el detalle (pon entre comillas lo que lleve espacios)."
            case .unknownOption(let option): "Opción desconocida: \(option)"
            case .missingValue(let option): "A \(option) le falta su valor."
            case .invalidBundleID(let id): "«\(id)» no es un identificador de app."
            case .invalidNumber(let text): "«\(text)» no es un número."
            }
        }
    }

    /// `yb aviso "título" ["detalle"] [--ok|--error|--info] [--app <bundle id>]`, sin el `aviso` de delante. `terminal` y `pid` los
    /// pone `yb` (`$TERM_PROGRAM` y su proceso padre)
    static func aviso(_ arguments: [String], terminal: String = "", pid: Int32? = nil) -> Result<TerminalNotice, Failure> {
        var words: [String] = []
        var status = TerminalNotice.Status.info
        var app: String?
        var onlyWords = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if onlyWords || !argument.hasPrefix("-") || argument == "-" {
                words.append(argument)
                continue
            }
            switch argument {
            case "--": onlyWords = true
            case "--ok": status = .ok
            case "--error": status = .error
            case "--info": status = .info
            case "--app":
                guard let value = iterator.next() else { return .failure(.missingValue(argument)) }
                guard BundleIdentifier.isValid(value) else { return .failure(.invalidBundleID(value)) }
                app = value
            default:
                return .failure(.unknownOption(argument))
            }
        }
        guard let title = words.first, !ClaudeHookText.clean(title).isEmpty else { return .failure(.missingTitle) }
        guard words.count <= 2 else { return .failure(.tooManyWords) }
        return .success(
            TerminalNotice(
                source: .custom(title: title, detail: words.count == 2 ? words[1] : "", status: status), terminal: terminal, pid: pid,
                appBundleID: app
            )
        )
    }

    /// `yb command-done <programa> <código> <segundos> [--terminal <TERM_PROGRAM>]`: lo que llaman los hooks de zsh
    static func commandDone(_ arguments: [String], pid: Int32? = nil) -> Result<TerminalNotice, Failure> {
        var words: [String] = []
        var terminal = ""
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--terminal" {
                guard let value = iterator.next() else { return .failure(.missingValue(argument)) }
                terminal = value
            } else if argument.hasPrefix("--") {
                return .failure(.unknownOption(argument))
            } else {
                words.append(argument)
            }
        }
        guard words.count == 3 else { return .failure(words.count < 3 ? .missingTitle : .tooManyWords) }
        guard let code = Int(words[1]) else { return .failure(.invalidNumber(words[1])) }
        guard let seconds = Int(words[2]) else { return .failure(.invalidNumber(words[2])) }
        return .success(TerminalNotice(source: .command(name: words[0], exitCode: code, seconds: seconds), terminal: terminal, pid: pid))
    }
}

// MARK: - El script de zsh

// Lo que imprime `yb shell-init zsh` y se carga con `eval` desde ~/.zshrc: un `preexec` apunta cuándo empieza cada comando y un
// `precmd` mira, al volver al prompt, si tardó lo bastante para avisar. Solo viaja el nombre del programa, nunca la línea entera:
// puede llevar una clave o un token. Se avisa en segundo plano y sin salida, para no retrasar el prompt ni ensuciar la terminal.
enum ZshHook {
    static let defaultMinimumSeconds = 10
    /// Programas interactivos que tardan por su naturaleza: avisar al cerrarlos sería ruido. `YB_AVISO_IGNORE` los sustituye
    static let defaultIgnored = "vim nvim vi nano emacs less more man ssh mosh htop btop top tmux screen watch tail fzf claude fg bg zsh bash fish sh lazygit k9s"

    /// `executable` es la ruta de `yb`; el script la usa tal cual, sin buscarlo en el PATH
    static func script(executable: String) -> String {
        """
        # YabaiBar: avisa en la isla cuando un comando largo termina. Se carga desde ~/.zshrc con:
        #   eval "$(yb shell-init zsh)"
        # YB_AVISO_MIN=<segundos> cambia lo mínimo que tiene que tardar (\(defaultMinimumSeconds) por defecto; la app tiene su propio mínimo y manda
        # el más alto), YB_AVISO_IGNORE="vim ssh …" sustituye la lista de programas que no avisan y YB_AVISO_IGNORE_EXTRA="psql …" añade a
        # ella. Solo se manda el nombre del programa, no la línea entera.
        if zmodload zsh/datetime 2>/dev/null; then
          autoload -Uz add-zsh-hook
          typeset -g _yb_bin=\(quoted(executable))
          typeset -g _yb_ignore=\(quoted(defaultIgnored))
          typeset -g _yb_start= _yb_cmd=

          _yb_preexec() {
            _yb_start=$EPOCHSECONDS
            # El tercer argumento es la línea con los alias ya expandidos (`v` → `nvim`): así la lista de ignorados los ve
            _yb_cmd=${3:-$1}
          }

          _yb_precmd() {
            local code=$?
            [[ -n $_yb_start ]] || return 0
            local took=$(( EPOCHSECONDS - _yb_start )) cmd=$_yb_cmd min=${YB_AVISO_MIN:-\(defaultMinimumSeconds)}
            _yb_start= _yb_cmd=
            [[ $min == <-> ]] || min=\(defaultMinimumSeconds)
            (( took >= min )) || return 0
            # Ctrl-C (130) y Ctrl-Z (146 en macOS: 128 + SIGTSTP): estabas ahí
            (( code == 130 || code == 146 )) && return 0
            # El programa: sin las `VAR=valor` ni las opciones de delante, sin `sudo`, `time` y demás envoltorios, y sin el `cd x &&`
            # que suele ir antes (si no, «cd proyecto && nvim» avisaría de «cd»)
            local word name= skipping=
            for word in ${(z)cmd}; do
              if [[ -n $skipping ]]; then
                [[ $word == '&&' || $word == '||' || $word == ';' ]] && skipping=
                continue
              fi
              [[ $word == [A-Za-z_]*=* || $word == -* ]] && continue
              case ${word:t} in
                sudo|doas|time|nohup|env|command|noglob|exec|builtin|nocorrect|'('|'{') continue ;;
                cd|pushd|popd) skipping=1; continue ;;
              esac
              name=${word:t}
              break
            done
            [[ -n $name ]] || return 0
            [[ " ${YB_AVISO_IGNORE-$_yb_ignore} $YB_AVISO_IGNORE_EXTRA " == *" $name "* ]] && return 0
            [[ -x $_yb_bin ]] || return 0
            "$_yb_bin" command-done "$name" $code $took --terminal "${TERM_PROGRAM:-}" >/dev/null 2>&1 &!
          }

          add-zsh-hook preexec _yb_preexec
          add-zsh-hook precmd _yb_precmd
        fi

        """
    }

    /// Entre comillas simples, para que una ruta con espacios o con `$` llegue entera
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// La línea que se pone en ~/.zshrc con la ruta de `yb` (la de dentro de la app, que no depende del PATH). Si la app se mueve o se
    /// borra, la línea no hace nada en vez de quejarse en cada terminal nueva
    static func initLine(executable: String) -> String {
        "[[ -x \(quoted(executable)) ]] && eval \"$(\(quoted(executable)) shell-init zsh)\""
    }
}
