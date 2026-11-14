import Darwin
import Foundation

// yb: el ayudante de línea de comandos de YabaiBar.
//   yb claude-hook            lo ejecutan los hooks de Claude Code: lee por stdin el JSON del hook y se lo avisa a la app.
//   yb aviso "título" [...]   enseña un aviso en la isla desde un script.
//   yb shell-init zsh         imprime los hooks de zsh que avisan cuando un comando largo termina (ver TerminalNotice.swift).
//   yb command-done …         lo que llaman esos hooks de zsh; no es para usarlo a mano.
//
// Un hook nunca tiene que estorbar a Claude Code ni a la shell: `claude-hook` y `command-done` salen siempre con 0 y no escriben
// nada por la salida estándar (en UserPromptSubmit, lo que escribe un hook se añade al contexto de Claude). Si YabaiBar no está en
// marcha, el aviso se pierde y no pasa nada. `aviso` y `shell-init` sí salen con 2 si se usan mal.

/// Manda un aviso a la app. La notificación sale por otro proceso (notifyd): un instante para que le dé tiempo antes de terminar
func post(_ message: AvisoMessage) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(AvisoMessage.notificationName), object: nil, userInfo: message.userInfo, deliverImmediately: true
    )
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
}

func claudeHook() {
    // Un terminal sin nada por stdin (alguien lo ejecuta a mano) no se queda esperando
    guard isatty(STDIN_FILENO) == 0 else { return }
    // `readToEnd` lanza un error de Swift si stdin está cerrado; `readDataToEndOfFile` lanzaría una excepción de Objective-C y
    // `yb` saldría con 134
    guard let data = (try? FileHandle.standardInput.readToEnd()) ?? nil, let event = ClaudeHookInput.parse(data) else { return }
    post(AvisoMessage(event))
}

/// El proceso que lanzó a `yb`: normalmente la shell. La app sube desde él por los procesos padre hasta la app en que corre
func parentPID() -> Int32? {
    let pid = getppid()
    return pid > 1 ? pid : nil
}

func environment(_ name: String) -> String {
    ProcessInfo.processInfo.environment[name] ?? ""
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

/// La ruta real de este programa, sin enlaces: la que el script de zsh puede usar sin depender del PATH
func executablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(buffer, &resolved) != nil ? String(cString: resolved) : String(cString: buffer)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude-hook":
    claudeHook()
case "aviso":
    switch YbArguments.aviso(Array(arguments.dropFirst()), terminal: environment("TERM_PROGRAM"), pid: parentPID()) {
    case .success(let notice): post(AvisoMessage(notice))
    case .failure(let failure): fail(failure.message + "\n" + YbArguments.usage)
    }
case "command-done":
    // Lo llama la shell en segundo plano: un argumento raro se ignora sin decir nada
    if case .success(let notice) = YbArguments.commandDone(Array(arguments.dropFirst()), pid: parentPID()) {
        post(AvisoMessage(notice))
    }
case "shell-init":
    guard arguments.dropFirst().first == "zsh" else { fail("Por ahora solo zsh: yb shell-init zsh") }
    print(ZshHook.script(executable: executablePath()), terminator: "")
case "--version":
    print("yb 1.1")
default:
    fail(YbArguments.usage)
}
exit(0)
