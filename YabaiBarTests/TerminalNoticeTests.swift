import Foundation
import Testing
@testable import YabaiBar

// Los avisos de la terminal (fase 41): los argumentos de `yb`, cómo viaja el aviso, el script de zsh (con zsh de verdad y un `yb`
// falso que apunta lo que se le pide), cómo se dicen y qué hace la app con ellos.
struct YbArgumentsTests {
    private func notice(_ arguments: [String], terminal: String = "", pid: Int32? = nil) throws -> TerminalNotice {
        try YbArguments.aviso(arguments, terminal: terminal, pid: pid).get()
    }

    @Test func aTitleAloneIsAnInfoNotice() throws {
        let result = try notice(["Despliegue"], terminal: "ghostty", pid: 321)
        #expect(result.source == .custom(title: "Despliegue", detail: "", status: .info))
        #expect(result.terminal == "ghostty" && result.pid == 321 && result.appBundleID == nil)
        #expect(result.status == .info)
    }

    @Test func titleDetailAndStatusInAnyOrder() throws {
        #expect(try notice(["Hecho", "todo bien", "--ok"]).source == .custom(title: "Hecho", detail: "todo bien", status: .ok))
        #expect(try notice(["--error", "Falló", "el test"]).source == .custom(title: "Falló", detail: "el test", status: .error))
        // La última opción de estado manda
        #expect(try notice(["--ok", "T", "--error"]).status == .error)
    }

    @Test func anAppIsTakenWithItsValue() throws {
        let result = try notice(["T", "--app", "com.mitchellh.ghostty"])
        #expect(result.appBundleID == "com.mitchellh.ghostty")
        #expect(throws: Never.self) { try notice(["T", "--app", "com.apple.Terminal", "--ok"]) }
    }

    @Test func aTitleThatStartsWithADashNeedsTheDoubleDash() throws {
        #expect(try notice(["--", "-x falló"]).source == .custom(title: "-x falló", detail: "", status: .info))
        #expect(YbArguments.aviso(["-x falló"]) == .failure(.unknownOption("-x falló")))
        // Un guion solo es una palabra, no una opción
        #expect(try notice(["-"]).source == .custom(title: "-", detail: "", status: .info))
    }

    @Test func badUsageSaysWhat() {
        #expect(YbArguments.aviso([]) == .failure(.missingTitle))
        #expect(YbArguments.aviso(["--ok"]) == .failure(.missingTitle))
        #expect(YbArguments.aviso(["   "]) == .failure(.missingTitle))
        #expect(YbArguments.aviso(["a", "b", "c"]) == .failure(.tooManyWords))
        #expect(YbArguments.aviso(["a", "--nada"]) == .failure(.unknownOption("--nada")))
        #expect(YbArguments.aviso(["a", "--app"]) == .failure(.missingValue("--app")))
        #expect(YbArguments.aviso(["a", "--app", "no es un id"]) == .failure(.invalidBundleID("no es un id")))
        #expect(YbArguments.aviso(["a", "--app", "../../x"]) == .failure(.invalidBundleID("../../x")))
        #expect(!YbArguments.Failure.missingTitle.message.isEmpty)
        #expect(YbArguments.usage.contains("yb aviso") && YbArguments.usage.contains("shell-init zsh"))
    }

    @Test func commandDoneTakesTheNameTheCodeAndTheSeconds() throws {
        let result = try YbArguments.commandDone(["npm", "1", "42", "--terminal", "WarpTerminal"], pid: 9).get()
        #expect(result.source == .command(name: "npm", exitCode: 1, seconds: 42))
        #expect(result.terminal == "WarpTerminal" && result.pid == 9)
        #expect(try YbArguments.commandDone(["make", "0", "11"]).get().terminal == "")
        #expect(YbArguments.commandDone(["make", "0"]) == .failure(.missingTitle))
        #expect(YbArguments.commandDone(["make", "0", "1", "2"]) == .failure(.tooManyWords))
        #expect(YbArguments.commandDone(["make", "x", "1"]) == .failure(.invalidNumber("x")))
        #expect(YbArguments.commandDone(["make", "0", "1.5"]) == .failure(.invalidNumber("1.5")))
        #expect(YbArguments.commandDone(["make", "0", "1", "--terminal"]) == .failure(.missingValue("--terminal")))
        #expect(YbArguments.commandDone(["make", "0", "1", "--otra"]) == .failure(.unknownOption("--otra")))
    }
}

// MARK: - El aviso por el sistema

struct TerminalMessageTests {
    private func roundTrip(_ notice: TerminalNotice) -> TerminalNotice? {
        let message = AvisoMessage(notice)
        // Pasa por el diccionario de la notificación, como en el viaje de verdad
        return AvisoMessage(userInfo: message.userInfo)?.terminalNotice
    }

    @Test func aCommandSurvivesTheTrip() {
        let notice = TerminalNotice(source: .command(name: "cargo", exitCode: 101, seconds: 75), terminal: "ghostty", pid: 4242)
        #expect(roundTrip(notice) == notice)
        #expect(AvisoMessage(notice).kind == .terminal)
        #expect(AvisoMessage(notice).claudeEvent == nil)
    }

    @Test func aCustomNoticeSurvivesTheTrip() {
        let notice = TerminalNotice(source: .custom(title: "Listo", detail: "build 42", status: .ok), appBundleID: "com.apple.Terminal")
        #expect(roundTrip(notice) == notice)
        // Un aviso sin pid ni terminal
        let bare = TerminalNotice(source: .custom(title: "Listo", detail: "", status: .error))
        #expect(roundTrip(bare) == bare)
    }

    // Cualquier proceso puede mandar uno con nuestro nombre: lo que llega se limpia y se acota
    @Test func whatArrivesIsCleanedAndBounded() throws {
        func message(_ fields: [String: String]) -> AvisoMessage { AvisoMessage(kind: .terminal, fields: fields) }
        let long = String(repeating: "a", count: 300)
        let cleaned = try #require(message(["event": "custom", "title": "uno\ndos\t\(long)", "detail": long, "terminal": long]).terminalNotice)
        guard case .custom(let title, let detail, let status) = cleaned.source else {
            Issue.record("no es un aviso a mano")
            return
        }
        #expect(!title.contains("\n") && !title.contains("\t") && title.count <= 80)
        #expect(detail.count <= 120 && cleaned.terminal.count <= 40)
        #expect(status == .info)
        // El nombre de un programa también se acota
        guard case .command(let name, _, _)? = message(["event": "command", "name": long, "exit": "0", "seconds": "12"]).terminalNotice?.source
        else {
            Issue.record("no es un comando")
            return
        }
        #expect(name.count <= 40)
    }

    @Test func nonsenseIsRejected() {
        func message(_ fields: [String: String]) -> AvisoMessage { AvisoMessage(kind: .terminal, fields: fields) }
        #expect(message([:]).terminalNotice == nil)
        #expect(message(["event": "otra"]).terminalNotice == nil)
        #expect(message(["event": "custom", "title": "  "]).terminalNotice == nil)
        #expect(message(["event": "command", "name": "", "exit": "0", "seconds": "12"]).terminalNotice == nil)
        #expect(message(["event": "command", "name": "x", "exit": "abc", "seconds": "12"]).terminalNotice == nil)
        #expect(message(["event": "command", "name": "x", "exit": "0", "seconds": "-5"]).terminalNotice == nil)
        #expect(message(["event": "command", "name": "x", "exit": "0", "seconds": "99999999"]).terminalNotice == nil)
        #expect(message(["event": "command", "name": "x", "exit": "9999", "seconds": "12"]).terminalNotice == nil)
        // Un aviso de Claude no es de la terminal, y al revés
        #expect(AvisoMessage(kind: .claudeHook, fields: ["event": "custom", "title": "x"]).terminalNotice == nil)
    }

    @Test func aBadPidOrAppIsDroppedButTheNoticeStays() throws {
        let base = ["event": "custom", "title": "Hecho"]
        let result = try #require(AvisoMessage(kind: .terminal, fields: base.merging(["pid": "1", "app": "../x"]) { _, new in new }).terminalNotice)
        #expect(result.pid == nil && result.appBundleID == nil)
        #expect(try #require(AvisoMessage(kind: .terminal, fields: base.merging(["pid": "-4"]) { _, new in new }).terminalNotice).pid == nil)
        #expect(try #require(AvisoMessage(kind: .terminal, fields: base.merging(["pid": "1234"]) { _, new in new }).terminalNotice).pid == 1234)
    }

    @Test func theBundleIdentifierShapeIsStrict() {
        for id in ["com.apple.Terminal", "dev.warp.Warp-Stable", "a", "org.alacritty"] { #expect(BundleIdentifier.isValid(id), "\(id)") }
        for id in ["", ".com", "-x", "com apple", "com/apple", "com.apple;rm", String(repeating: "a", count: 101), "é.com"] {
            #expect(!BundleIdentifier.isValid(id), "\(id)")
        }
    }
}

// MARK: - El script de zsh

// Con zsh de verdad: se carga el script y se llaman sus dos funciones como lo haría el shell al ejecutar un comando y volver al
// prompt. `yb` es un script que apunta lo que recibe. Los avisos salen en segundo plano (`&!`): se espera a que lleguen
struct ZshHookTests {
    /// Un `yb` falso que apunta los argumentos que recibe. `directory` puede llevar espacios y apóstrofos, como una ruta de verdad
    private func fakeYb(in directory: URL) throws -> (path: String, log: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(path: "llamadas.log")
        let path = directory.appending(path: "yb").path
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ZshHook.quoted(log.path))\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, log)
    }

    /// Ejecuta `commands` en un zsh sin configuración con el script ya cargado y devuelve las llamadas que recibió el `yb` falso.
    /// Con `expectCalls`, espera (hasta 5 s) a que lleguen esas, y un momento más por si llegan de sobra; sin ellas, espera un
    /// momento fijo por si llega alguna
    private func run(
        _ commands: String, environment: [String: String] = [:], executable: String? = nil, directory: URL? = nil, expectCalls: Int = 0
    ) throws -> [String] {
        let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "zsh-hook-\(UUID().uuidString)")
        let (path, log) = try fakeYb(in: directory)
        let script = directory.appending(path: "init.zsh")
        try ZshHook.script(executable: executable ?? path).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-f", "-c", "source \(ZshHook.quoted(script.path)); \(commands)"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "TERM_PROGRAM": "ghostty"].merging(environment) { _, new in new }
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && stderr.isEmpty, "zsh: \(process.terminationStatus) \(stderr)")
        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        }
        let deadline = Date().addingTimeInterval(5)
        while calls().count < expectCalls, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: expectCalls > 0 ? 0.3 : 0.4)
        return calls()
    }

    private let now = ["YB_AVISO_MIN": "0"]

    @Test func aLongCommandNotifiesWithItsProgramNameCodeAndTime() throws {
        let calls = try run(#"_yb_preexec "FOO=1 /opt/bin/npm test --token secreto"; false; _yb_precmd"#, environment: now, expectCalls: 1)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        // Solo el programa, sin las variables delante, la ruta ni los argumentos (puede haber claves)
        #expect(call.hasPrefix("command-done npm 1 ") && call.hasSuffix(" --terminal ghostty"), "\(call)")
        #expect(!call.contains("secreto") && !call.contains("test") && !call.contains("FOO"))
        let seconds = try #require(Int(call.split(separator: " ")[3]))
        #expect((0...2).contains(seconds))
    }

    @Test func aSuccessfulCommandSaysZero() throws {
        let calls = try run(#"_yb_preexec "make"; true; _yb_precmd"#, environment: now, expectCalls: 1)
        #expect(calls.first?.hasPrefix("command-done make 0 ") == true)
    }

    // El programa es el de verdad: sin `sudo`, `time` y demás envoltorios, y sin el `cd x &&` de delante
    @Test(arguments: [
        ("npm test", "npm"), ("FOO=1 /opt/bin/npm test", "npm"), ("cd proyecto && npm run build", "npm"), ("cd x; make", "make"),
        ("sudo make install", "make"), ("time cargo build", "cargo"), ("nohup ./run.sh", "run.sh"), ("env FOO=1 make", "make"),
        ("(cd x && make)", "make"), ("pushd x && cmake ..", "cmake"), ("{ make; }", "make"), ("cd x || make", "make"),
        ("make -j8", "make"),
    ])
    func theProgramIsTheRealOne(commandLine: String, program: String) throws {
        let calls = try run("_yb_preexec \(ZshHook.quoted(commandLine)); true; _yb_precmd", environment: now, expectCalls: 1)
        #expect(calls.first?.hasPrefix("command-done \(program) 0 ") == true, "\(commandLine) → \(calls)")
    }

    // Lo que termina siendo un programa ignorado (aunque vaya tras un `cd`) o no es un programa, no avisa
    @Test(arguments: ["cd proyecto && nvim", "cd x", "fg", "bg", "sudo vim /etc/hosts", "zsh", "time ssh servidor"])
    func noProgramOrAnIgnoredOneDoesNotNotify(commandLine: String) throws {
        #expect(try run("_yb_preexec \(ZshHook.quoted(commandLine)); true; _yb_precmd", environment: now).isEmpty, "\(commandLine)")
    }

    // Lo que ve la lista de ignorados es lo que se ejecuta de verdad (el tercer argumento de preexec, con los alias expandidos)
    @Test func aliasesAreSeenAsWhatTheyRun() throws {
        #expect(try run(#"_yb_preexec "v notas.md" "v notas.md" "nvim notas.md"; true; _yb_precmd"#, environment: now).isEmpty)
        let calls = try run(#"_yb_preexec "b" "b" "make all"; true; _yb_precmd"#, environment: now, expectCalls: 1)
        #expect(calls.first?.hasPrefix("command-done make 0 ") == true)
    }

    @Test func aShortCommandDoesNotNotifyAndTheDefaultIsTenSeconds() throws {
        #expect(try run(#"_yb_preexec "npm test"; true; _yb_precmd"#).isEmpty)
        #expect(try run(#"_yb_preexec "npm test"; true; _yb_precmd"#, environment: ["YB_AVISO_MIN": "100"]).isEmpty)
        // Un valor que no es un número vuelve al de siempre
        #expect(try run(#"_yb_preexec "npm test"; true; _yb_precmd"#, environment: ["YB_AVISO_MIN": "abc"]).isEmpty)
        // Pasados los segundos, avisa: se adelanta el reloj del comando
        #expect(try run(#"_yb_preexec "npm test"; _yb_start=$(( EPOCHSECONDS - 11 )); true; _yb_precmd"#, expectCalls: 1).count == 1)
        #expect(try run(#"_yb_preexec "npm test"; _yb_start=$(( EPOCHSECONDS - 9 )); true; _yb_precmd"#).isEmpty)
    }

    @Test func interactiveProgramsAndInterruptionsDoNotNotify() throws {
        for program in ["vim notas.md", "ssh servidor", "tail -f log", "claude", "/usr/bin/less x"] {
            #expect(try run("_yb_preexec \(ZshHook.quoted(program)); true; _yb_precmd", environment: now).isEmpty, "\(program)")
        }
        // Ctrl-C (130) y Ctrl-Z (146 en macOS: 128 + SIGTSTP, comprobado en una terminal de verdad)
        #expect(try run(#"_yb_preexec "make"; (exit 130); _yb_precmd"#, environment: now).isEmpty)
        #expect(try run(#"_yb_preexec "make"; (exit 146); _yb_precmd"#, environment: now).isEmpty)
        // Otros códigos sí avisan
        #expect(try run(#"_yb_preexec "make"; (exit 148); _yb_precmd"#, environment: now, expectCalls: 1).count == 1)
    }

    // YB_AVISO_IGNORE sustituye a la lista y YB_AVISO_IGNORE_EXTRA le añade
    @Test func theIgnoreListCanBeReplacedOrExtended() throws {
        let replaced = now.merging(["YB_AVISO_IGNORE": "npm"]) { _, new in new }
        #expect(try run(#"_yb_preexec "npm i"; true; _yb_precmd"#, environment: replaced).isEmpty)
        #expect(try run(#"_yb_preexec "vim x"; true; _yb_precmd"#, environment: replaced, expectCalls: 1).count == 1)
        let extended = now.merging(["YB_AVISO_IGNORE_EXTRA": "psql lazydocker"]) { _, new in new }
        #expect(try run(#"_yb_preexec "psql -h x"; true; _yb_precmd"#, environment: extended).isEmpty)
        #expect(try run(#"_yb_preexec "vim x"; true; _yb_precmd"#, environment: extended).isEmpty)
        #expect(try run(#"_yb_preexec "make"; true; _yb_precmd"#, environment: extended, expectCalls: 1).count == 1)
    }

    @Test func aPromptWithoutACommandAndAReusedPromptDoNotNotify() throws {
        // Intro en un prompt vacío: precmd sin preexec
        #expect(try run("_yb_precmd", environment: now).isEmpty)
        // Un comando avisa una sola vez, aunque el prompt se dibuje otra vez
        #expect(try run(#"_yb_preexec "make"; true; _yb_precmd; _yb_precmd"#, environment: now, expectCalls: 1).count == 1)
    }

    @Test func aCommandOfOnlyAssignmentsOrNothingDoesNotNotify() throws {
        #expect(try run(#"_yb_preexec "FOO=1 BAR=2"; true; _yb_precmd"#, environment: now).isEmpty)
        #expect(try run(#"_yb_preexec ""; true; _yb_precmd"#, environment: now).isEmpty)
    }

    @Test func aMissingHelperIsNotAnError() throws {
        #expect(try run(#"_yb_preexec "make"; true; _yb_precmd"#, environment: now, executable: "/no/existe/yb").isEmpty)
    }

    // Una ruta con espacios y un apóstrofo llega entera
    @Test func aTrickyPathWorks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Mi App d'Ana \(UUID().uuidString)")
        let calls = try run(#"_yb_preexec "make"; true; _yb_precmd"#, environment: now, directory: directory, expectCalls: 1)
        #expect(calls.count == 1)
    }

    @Test func theHooksAreRegisteredAndNeverTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "zsh-hook-\(UUID().uuidString)")
        let (path, _) = try fakeYb(in: directory)
        let script = ZshHook.script(executable: path)
        // Cargarlo dos veces no duplica los hooks
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        let file = directory.appending(path: "init.zsh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        process.arguments = ["-f", "-c", "source '\(file.path)'; source '\(file.path)'; print -l -- $preexec_functions; print -- '---'; print -l -- $precmd_functions"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines == ["_yb_preexec", "---", "_yb_precmd"], "\(lines)")
    }

    @Test func theScriptSaysHowToLoadItAndTheLineQuotesThePath() {
        let script = ZshHook.script(executable: "/Applications/YabaiBar.app/Contents/Helpers/yb")
        #expect(script.contains("eval \"$(yb shell-init zsh)\""))
        #expect(script.contains("YB_AVISO_MIN") && script.contains("YB_AVISO_IGNORE") && script.contains("YB_AVISO_IGNORE_EXTRA"))
        #expect(script.contains("'/Applications/YabaiBar.app/Contents/Helpers/yb'"))
        // La línea de ~/.zshrc no hace nada (ni se queja en cada terminal) si la app ya no está donde estaba
        #expect(ZshHook.initLine(executable: "/Users/o'brien/YabaiBar.app/Contents/Helpers/yb")
            == "[[ -x '/Users/o'\\''brien/YabaiBar.app/Contents/Helpers/yb' ]] && eval \"$('/Users/o'\\''brien/YabaiBar.app/Contents/Helpers/yb' shell-init zsh)\"")
        #expect(ZshHook.quoted("a b") == "'a b'")
    }

    @Test func theLineInZshrcDoesNothingWhenTheAppIsGone() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-f", "-c", ZshHook.initLine(executable: "/no/existe/yb")]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}

// MARK: - El ayudante de verdad

struct TerminalHelperTests {
    private var helper: String { Bundle.main.bundleURL.appending(path: "Contents/Helpers/yb").path }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(filePath: helper)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    // `yb aviso` y `command-done` mandarían un aviso de verdad a la app que corra: aquí solo los usos que no llegan a mandar nada
    @Test func badUsageExitsWithTwoAndSaysWhy() throws {
        for arguments in [["aviso"], ["aviso", "--ok"], ["aviso", "a", "--nada"], ["aviso", "a", "--app", "no es un id"], [], ["otra-cosa"]] {
            let result = try run(arguments)
            #expect(result.status == 2 && result.output.isEmpty && result.errors.contains("Uso:"), "\(arguments): \(result.status) \(result.errors)")
        }
    }

    @Test func commandDoneWithGarbageIsSilent() throws {
        for arguments in [["command-done"], ["command-done", "x", "y", "z"], ["command-done", "x", "0", "1", "--otra"]] {
            let result = try run(arguments)
            #expect(result.status == 0 && result.output.isEmpty && result.errors.isEmpty, "\(arguments)")
        }
    }

    @Test func shellInitPrintsAScriptThatPointsAtTheHelperItself() throws {
        let result = try run(["shell-init", "zsh"])
        #expect(result.status == 0 && result.errors.isEmpty)
        // La ruta real del propio `yb`, entre comillas: no depende del PATH
        let real = URL(filePath: helper).resolvingSymlinksInPath().path
        #expect(result.output.contains(ZshHook.quoted(real)) || result.output.contains(ZshHook.quoted("/private" + real)), "\(real)")
        #expect(result.output.contains("_yb_precmd") && result.output.contains("add-zsh-hook preexec _yb_preexec"))
        // Otras shells no
        let fish = try run(["shell-init", "fish"])
        #expect(fish.status == 2 && fish.output.isEmpty)
        #expect(try run(["shell-init"]).status == 2)
        #expect(try run(["--version"]).output.hasPrefix("yb "))
    }
}

// MARK: - Cómo se dice un aviso

struct TerminalNoticeTextTests {
    private func command(_ code: Int, _ seconds: Int, terminal: String = "ghostty") -> TerminalNotice {
        TerminalNotice(source: .command(name: "npm", exitCode: code, seconds: seconds), terminal: terminal)
    }

    @Test func aFinishedCommandSaysItsNameAndHowItWent() {
        #expect(TerminalNoticeText.title(command(0, 45)) == "npm terminó")
        #expect(TerminalNoticeText.title(command(1, 45)) == "npm falló")
        #expect(TerminalNoticeText.subtitle(command(0, 45)) == "45 s")
        #expect(TerminalNoticeText.subtitle(command(0, 145)) == "2 min")
        #expect(TerminalNoticeText.subtitle(command(101, 45)) == "código 101 · 45 s")
        #expect(TerminalNoticeText.detail(command(1, 45)) == "código 1 · 45 s · Ghostty")
        // Una terminal que no se conoce sale tal cual; sin terminal, no sale
        #expect(TerminalNoticeText.detail(command(0, 45, terminal: "mi-term")) == "45 s · mi-term")
        #expect(TerminalNoticeText.detail(command(0, 45, terminal: "")) == "45 s")
    }

    @Test func aNoticeByHandSaysWhatItWasGiven() {
        let notice = TerminalNotice(source: .custom(title: "Despliegue", detail: "en producción", status: .ok), terminal: "vscode")
        #expect(TerminalNoticeText.title(notice) == "Despliegue")
        #expect(TerminalNoticeText.subtitle(notice) == "en producción")
        #expect(TerminalNoticeText.detail(notice) == "en producción · VS Code")
        #expect(TerminalNoticeText.detail(TerminalNotice(source: .custom(title: "x", detail: "", status: .info))) == "")
    }

    @Test func theIslandShowsItWithItsToneAndAnErrorStaysLonger() {
        let ok = TerminalNoticeText.islandNotice(command(0, 45))
        #expect(ok.symbol == "checkmark.circle.fill" && ok.tone == .ok && !ok.isUrgent)
        let failed = TerminalNoticeText.islandNotice(command(2, 45))
        #expect(failed.symbol == "xmark.octagon.fill" && failed.tone == .error && failed.isUrgent)
        let info = TerminalNoticeText.islandNotice(TerminalNotice(source: .custom(title: "x", detail: "", status: .info)))
        #expect(info.tone == .info && info.priority == 20)
        #expect(IslandPeek.notice(failed).duration == .seconds(8) && IslandPeek.notice(ok).duration == .seconds(5))
        #expect(TerminalNoticeText.rowTone(.ok) == .ok && TerminalNoticeText.rowTone(.error) == .alert && TerminalNoticeText.rowTone(.info) == .active)
    }

    @Test func knownTerminalsHaveANameAndAnIdentifier() {
        for (program, name, id) in [
            ("ghostty", "Ghostty", "com.mitchellh.ghostty"), ("WarpTerminal", "Warp", "dev.warp.Warp-Stable"),
            ("Apple_Terminal", "Terminal", "com.apple.Terminal"), ("vscode", "VS Code", "com.microsoft.VSCode"),
            ("iTerm.app", "iTerm", "com.googlecode.iterm2"),
        ] {
            #expect(TerminalApp.displayName(forProgram: program) == name)
            #expect(TerminalApp.bundleID(forProgram: program) == id)
            #expect(BundleIdentifier.isValid(id))
        }
        #expect(TerminalApp.bundleID(forProgram: "desconocida") == nil)
        #expect(TerminalApp.bundleID(forProgram: "") == nil)
    }
}

// MARK: - Qué hace la app con él

@MainActor
struct TerminalNoticesTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "terminal-tests-\(UUID().uuidString)")!)
    }

    private func message(_ code: Int = 0, seconds: Int = 30, terminal: String = "ghostty", pid: Int32? = nil, app: String? = nil) -> AvisoMessage {
        AvisoMessage(TerminalNotice(source: .command(name: "npm", exitCode: code, seconds: seconds), terminal: terminal, pid: pid, appBundleID: app))
    }

    private func handler(
        _ settings: AppSettings, frontmost: String? = nil, origins: [Int32: String] = [:]
    ) -> TerminalNotices {
        TerminalNotices(settings: settings, frontmost: { frontmost }, originOf: { origins[$0] })
    }

    @Test func aCommandBecomesAnEntryAndANotice() throws {
        let result = try #require(handler(settings()).handle(message(1, seconds: 125), now: Date(timeIntervalSince1970: 100)))
        #expect(result.entry.title == "npm falló" && result.entry.detail == "código 1 · 2 min · Ghostty")
        #expect(result.entry.tone == .alert && result.entry.date == Date(timeIntervalSince1970: 100))
        #expect(result.notice.title == "npm falló" && result.notice.tone == .error)
        #expect(result.failed && !result.suppressPeek)
        let ok = try #require(handler(settings()).handle(message(0)))
        #expect(!ok.failed && ok.entry.tone == .ok)
    }

    @Test func offOrBelowTheMinimumAcceptsNothing() {
        let settings = settings()
        settings.terminalNotices = false
        #expect(handler(settings).handle(message()) == nil)
        settings.terminalNotices = true
        settings.terminalMinSeconds = 60
        #expect(handler(settings).handle(message(seconds: 59)) == nil)
        #expect(handler(settings).handle(message(seconds: 60)) != nil)
        // Un aviso que no es de la terminal, o que no se entiende, tampoco
        #expect(handler(settings).handle(AvisoMessage(kind: .terminal, fields: [:])) == nil)
        #expect(handler(settings).handle(AvisoMessage(kind: .claudeHook, fields: ["event": "Stop", "session": "s"])) == nil)
    }

    // Un `yb aviso` a mano no tiene duración: el mínimo no le afecta
    @Test func aNoticeByHandIgnoresTheMinimum() throws {
        let settings = settings()
        settings.terminalMinSeconds = 120
        let custom = AvisoMessage(TerminalNotice(source: .custom(title: "Hecho", detail: "", status: .ok)))
        let result = try #require(handler(settings).handle(custom))
        #expect(result.entry.title == "Hecho" && !result.failed)
        // Un `yb aviso --error` también deja el punto rojo
        let error = AvisoMessage(TerminalNotice(source: .custom(title: "Falló", detail: "", status: .error)))
        #expect(try #require(handler(settings).handle(error)).failed)
    }

    @Test func theOriginIsTheExplicitAppThenTheProcessThenTheTerminalProgram() throws {
        let origins: [Int32: String] = [77: "com.microsoft.VSCode"]
        func origin(_ message: AvisoMessage) throws -> NoticeEntry.Origin {
            try #require(handler(settings(), origins: origins).handle(message)).entry.origin
        }
        #expect(try origin(message(pid: 77, app: "com.apple.Terminal")) == .terminal(bundleID: "com.apple.Terminal"))
        #expect(try origin(message(terminal: "ghostty", pid: 77)) == .terminal(bundleID: "com.microsoft.VSCode"))
        // Un proceso que ya no existe (o sin app de la que cuelgue): lo que dice $TERM_PROGRAM
        #expect(try origin(message(terminal: "ghostty", pid: 5)) == .terminal(bundleID: "com.mitchellh.ghostty"))
        #expect(try origin(message(terminal: "ghostty")) == .terminal(bundleID: "com.mitchellh.ghostty"))
        #expect(try origin(message(terminal: "desconocida")) == .terminal(bundleID: nil))
    }

    @Test func aCommandFinishingInFrontOfYouStaysOutOfTheIsland() throws {
        let settings = settings()
        let front = handler(settings, frontmost: "com.mitchellh.ghostty")
        let hidden = try #require(front.handle(message(terminal: "ghostty")))
        #expect(hidden.suppressPeek)
        // Queda en el módulo Avisos
        #expect(hidden.entry.title == "npm terminó")
        // Otra app delante: se enseña
        #expect(try #require(handler(settings, frontmost: "com.apple.Safari").handle(message(terminal: "ghostty"))).suppressPeek == false)
        // Sin saber de qué app viene, no se puede decir que esté delante
        #expect(try #require(handler(settings, frontmost: "com.apple.Safari").handle(message(terminal: "x"))).suppressPeek == false)
        // Con el ajuste, avisa igualmente
        settings.terminalWhenFrontmost = true
        #expect(try #require(front.handle(message(terminal: "ghostty"))).suppressPeek == false)
    }

    @Test func aNoticeByHandIsShownEvenWithTheTerminalInFront() throws {
        let custom = AvisoMessage(TerminalNotice(source: .custom(title: "Hecho", detail: "", status: .ok), terminal: "ghostty"))
        #expect(try #require(handler(settings(), frontmost: "com.mitchellh.ghostty").handle(custom)).suppressPeek == false)
    }

    // Un aviso falso que se haga pasar por una app que no está abierta no abre nada
    @Test func clickingNeverLaunchesAnAppThatIsNotRunning() {
        #expect(!TerminalNotices.activate(bundleID: "com.example.no-existe-\(UUID().uuidString)"))
        #expect(!TerminalNotices.activate(bundleID: "../../etc/passwd"))
        #expect(!TerminalNotices.activate(bundleID: ""))
    }
}

// MARK: - El módulo Avisos

struct NoticeRowsTests {
    private func entry(_ title: String, origin: NoticeEntry.Origin = .terminal(bundleID: "com.apple.Terminal"), tone: RowTone = .ok, age: TimeInterval = 0) -> NoticeEntry {
        NoticeEntry(date: Date(timeIntervalSince1970: 1_800_000_000 - age), tone: tone, title: title, detail: "detalle", origin: origin)
    }

    private let time: (Date) -> String = { "t\(Int($0.timeIntervalSince1970) % 1000)" }

    @Test func noEntriesSaysSo() {
        let content = NoticeRows.content(of: [], time: time)
        #expect(content.rows.isEmpty && content.notice?.title == "Sin avisos todavía")
    }

    @Test func theLastThreeShowWithTheirTimeAndTheOthersAreCounted() {
        let entries = (1...5).map { entry("aviso \($0)") }
        let content = NoticeRows.content(of: entries, time: time)
        #expect(content.rows.map(\.title) == ["aviso 1", "aviso 2", "aviso 3"])
        #expect(content.summary == "3 de 5")
        #expect(content.rows[0].trailing == "t0" && content.rows[0].detail == "detalle")
        #expect(NoticeRows.content(of: [entry("a")], time: time).summary == "1 aviso")
        #expect(NoticeRows.content(of: [entry("a"), entry("b")], time: time).summary == "2 avisos")
        #expect(Set(content.rows.map(\.id)).count == 3)
    }

    @Test func aClickGoesToTheOrigin() {
        #expect(NoticeRows.action(for: .terminal(bundleID: "com.apple.Terminal")) == .activate)
        #expect(NoticeRows.action(for: .terminal(bundleID: nil)) == nil)
        #expect(NoticeRows.action(for: .claude(sessionID: "s")) == .activate)
        #expect(NoticeRows.action(for: .git(repo: "tienda")) == .open)
        let rows = NoticeRows.content(
            of: [entry("t"), entry("sin app", origin: .terminal(bundleID: nil)), entry("g", origin: .git(repo: "r"))], time: time
        ).rows
        #expect(rows[0].primaryAction == .activate && rows[0].actions == [.activate])
        #expect(rows[1].primaryAction == nil && rows[1].actions.isEmpty)
        #expect(rows[2].primaryAction == .open)
    }
}

@MainActor
struct NoticeLogTests {
    @Test func keepsTheLastTenNewestFirst() {
        let log = NoticeLog()
        for index in 1...13 {
            log.record(NoticeEntry(date: Date(), tone: .ok, title: "aviso \(index)", detail: "", origin: .terminal(bundleID: nil)))
        }
        #expect(log.entries.count == 10)
        #expect(log.entries.first?.title == "aviso 13" && log.entries.last?.title == "aviso 4")
        let first = log.entries[0]
        #expect(log.entry(withID: first.id) == first)
        #expect(log.entry(withID: "no-existe") == nil)
    }

    // Un script que avisa en bucle no desaloja los avisos de Claude y de Git
    @Test func aRepeatedNoticeOnlyRefreshesItsTime() {
        let log = NoticeLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ title: String, at offset: TimeInterval, origin: NoticeEntry.Origin = .terminal(bundleID: nil)) -> NoticeEntry {
            NoticeEntry(date: start.addingTimeInterval(offset), tone: .ok, title: title, detail: "d", origin: origin)
        }
        log.record(entry("Claude pregunta", at: 0, origin: .claude(sessionID: "s")))
        for index in 1...30 { log.record(entry("npm falló", at: TimeInterval(index))) }
        #expect(log.entries.map(\.title) == ["npm falló", "Claude pregunta"])
        #expect(log.entries[0].date == start.addingTimeInterval(30))
        // Pasado el minuto, o con otro origen, se apunta otra vez
        log.record(entry("npm falló", at: 100))
        #expect(log.entries.count == 3)
        log.record(entry("npm falló", at: 101, origin: .terminal(bundleID: "com.apple.Terminal")))
        #expect(log.entries.count == 4)
    }

    @Test func gitAndClaudeNoticesBecomeEntries() {
        let date = Date(timeIntervalSince1970: 5)
        let failed = GitNotice(repo: "tienda", kind: .ci(.failed)).entry(date: date)
        #expect(failed.tone == .alert && failed.title == "CI falló" && failed.detail == "tienda" && failed.origin == .git(repo: "tienda"))
        #expect(GitNotice(repo: "r", kind: .ci(.passed)).entry(date: date).tone == .ok)
        #expect(GitNotice(repo: "r", kind: .unpushed(commits: 2)).entry(date: date).tone == .attention)
        #expect(GitNotice(repo: "r", kind: .uncommitted(files: 1)).rowTone == .attention)
        #expect(GitNotice(repo: "r", kind: .unreleased(tag: "v1")).rowTone == .attention)
        let asks = ClaudePeek(kind: .asks, folder: "tienda", detail: "Necesita tu permiso").entry(sessionID: "s1", date: date)
        #expect(asks.tone == .attention && asks.title == "Claude pregunta" && asks.detail == "tienda · Necesita tu permiso")
        #expect(asks.origin == .claude(sessionID: "s1"))
        #expect(ClaudePeek(kind: .finished, folder: "x", detail: "tras 2 min").entry(sessionID: "s", date: date).tone == .ok)
    }

    #if DEBUG
    @Test func theDemoGivesBackWhatWasThere() {
        let log = NoticeLog()
        log.record(NoticeEntry(date: Date(), tone: .ok, title: "de verdad", detail: "", origin: .terminal(bundleID: nil)))
        log.injectDemo()
        #expect(log.entries.count == 4 && log.entries.first?.title != "de verdad")
        log.resetInjected()
        #expect(log.entries.map(\.title) == ["de verdad"])
    }
    #endif
}

@MainActor
struct NoticesModuleTests {
    @Test func theDeveloperModuleListsTheLogAndGoesToItsSource() throws {
        let defaults = UserDefaults(suiteName: "notices-module-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let log = NoticeLog()
        let tools = DevTools(
            system: SystemMonitor(), ports: PortsMonitor(), docker: DockerMonitor(executable: nil),
            claude: try ClaudeTestSupport.sessions(), git: GitMonitor(git: nil, gh: nil, settings: settings), notices: log, settings: settings
        )
        #expect(tools.rowsContent()[.notices]?.notice?.title == "Sin avisos todavía")
        log.record(NoticeEntry(date: Date(), tone: .alert, title: "npm falló", detail: "x", origin: .terminal(bundleID: nil)))
        let rows = try #require(tools.rowsContent()[.notices]?.rows)
        #expect(rows.map(\.title) == ["npm falló"])
        // Un clic en un aviso de una terminal que no se conoce, o de un repositorio que ya no está, no hace nada ni rompe
        #expect(tools.perform(ModuleControl(module: .notices, row: rows[0].id, action: .activate)) == nil)
        log.record(NoticeEntry(date: Date(), tone: .attention, title: "g", detail: "r", origin: .git(repo: "no-existe")))
        #expect(tools.perform(ModuleControl(module: .notices, row: log.entries[0].id, action: .open)) == nil)
        #expect(tools.perform(ModuleControl(module: .notices, row: "otro-id", action: .activate)) == nil)
    }
}
