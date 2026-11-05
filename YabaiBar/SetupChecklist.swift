import Foundation

// Lógica pura de "Primeros pasos": de lo que se sabe del Mac, de yabai y de los permisos al estado de cada
// requisito y a lo que se ofrece para arreglarlo. La ventana (WelcomeWindow) reúne los datos y dibuja las filas.
enum SetupChecklist {
    enum Item: Hashable {
        case model
        case yabaiInstalled
        case yabaiRunning
        case signals
        case desktopShortcuts
        case accessibility
        case launchAtLogin
    }

    enum Status: Equatable {
        case ok
        /// Funciona, pero no del todo
        case warning
        /// Falta y algo no va a funcionar
        case missing
    }

    /// El control de la fila
    enum Action: Equatable {
        /// Copiar los datos del Mac y de sus pantallas, para pegarlos en un issue
        case copyScreenReport
        /// Copiar el comando de Homebrew y abrir la wiki de yabai
        case installYabai
        /// Copiar `yabai --start-service`
        case startYabai
        case signalsToggle
        /// Abrir Ajustes › Teclado
        case keyboardSettings
        case requestAccessibility
        case launchAtLoginToggle
    }

    struct Row: Equatable {
        let item: Item
        let status: Status
        let title: String
        let detail: String
        var action: Action?
    }

    /// Lo que se sabe de una pantalla conectada, en puntos
    struct Screen: Equatable {
        var name: String
        var size: CGSize
        /// `backingScaleFactor`
        var scale: CGFloat
        /// El notch medido (NotchGeometry); nil si la pantalla no tiene
        var notch: CGSize?
        /// Lo que ocupa la barra de menús; 0 si se oculta sola
        var menuBarHeight: CGFloat
    }

    struct Inputs: Equatable {
        /// `hw.model`, por ejemplo "MacBookPro18,1"
        var model: String
        var screens: [Screen]
        var yabaiInstalled: Bool
        /// El último error de yabai; nil si respondió
        var yabaiError: YabaiError?
        var signalsEnabled: Bool
        /// Los escritorios que hay y los que tienen el atajo "Ir al escritorio N" de Mission Control
        var desktops: [Int]
        var desktopsWithShortcut: Set<Int>
        var accessibility: Bool
        var launchAtLoginAvailable: Bool
        var launchAtLogin: Bool
    }

    static let installYabai = "brew install asmvik/formulae/yabai"
    static let startYabai = "yabai --start-service"
    static let yabaiWiki = URL(string: "https://github.com/asmvik/yabai/wiki")!

    static func rows(for inputs: Inputs) -> [Row] {
        [
            modelRow(inputs),
            inputs.yabaiInstalled
                ? Row(
                    item: .yabaiInstalled, status: .ok, title: "yabai instalado",
                    detail: "Lo configuras tú, con tu yabairc: YabaiBar no lo toca ni necesita la scripting addition."
                )
                : Row(
                    item: .yabaiInstalled, status: .missing, title: "yabai instalado",
                    detail: "Instálalo con Homebrew y configúralo leyendo antes su wiki: \(installYabai)",
                    action: .installYabai
                ),
            runningRow(inputs),
            Row(
                item: .signals, status: inputs.signalsEnabled ? .ok : .warning, title: "Señales de yabai",
                detail: inputs.signalsEnabled
                    ? "YabaiBar las añade sola: la isla se refresca al crear, cerrar o minimizar ventanas."
                    : "Apagadas: la isla solo se refresca al cambiar de escritorio o de app. Si las tienes en tu yabairc, vuelven al reiniciar yabai.",
                action: .signalsToggle
            ),
            shortcutsRow(inputs),
            inputs.accessibility
                ? Row(
                    item: .accessibility, status: .ok, title: "Accesibilidad",
                    detail: "Un clic en una tarjeta de la isla abierta te lleva a ese escritorio."
                )
                : Row(
                    item: .accessibility, status: .missing, title: "Accesibilidad",
                    detail: "Para que un clic en una tarjeta pulse el atajo del escritorio. Lo demás funciona sin ella.",
                    action: .requestAccessibility
                ),
            launchRow(inputs),
        ]
    }

    // Cualquier Mac con notch vale: la isla mide el notch en la pantalla. El catálogo solo pone el nombre
    private static func modelRow(_ inputs: Inputs) -> Row {
        let known = MacModels.model(for: inputs.model)
        let mac = known?.name ?? (inputs.model.isEmpty ? "Modelo desconocido" : "Modelo \(inputs.model)")
        if let notch = inputs.screens.lazy.compactMap(\.notch).first {
            let tested = known == nil ? ", aún sin probar" : ""
            return Row(
                item: .model, status: .ok, title: "Mac con notch",
                detail: "\(mac)\(tested). La isla se ajusta a tu notch: \(Int(notch.width.rounded())) × \(Int(notch.height.rounded())) pt con la escala de pantalla actual.",
                action: .copyScreenReport
            )
        }
        let closedLid = known?.hasNotch == true ? " con la tapa cerrada" : ""
        return Row(
            item: .model, status: .warning, title: "Pantalla sin notch",
            detail: "\(mac)\(closedLid): sin notch, la isla se dibuja sobre uno de reserva y puede verse descolocada. Los monitores y los Mac sin notch llegarán en una próxima versión.",
            action: .copyScreenReport
        )
    }

    /// Los datos del Mac y de cada pantalla que copia «Copiar datos», para pegarlos en un issue. Sin nada personal
    static func screenReport(model: String, appVersion: String, system: String, screens: [Screen]) -> String {
        let name = MacModels.model(for: model)?.name ?? "modelo no reconocido"
        let header = [
            "YabaiBar \(appVersion) · \(system)",
            "Mac: \(model.isEmpty ? "desconocido" : model) (\(name))",
        ]
        let lines = screens.enumerated().map { offset, screen in
            [
                "Pantalla \(offset + 1): \(screen.name)",
                "\(number(screen.size.width)) × \(number(screen.size.height)) pt",
                "×\(number(screen.scale))",
                screen.notch.map { "notch \(number($0.width)) × \(number($0.height)) pt" } ?? "sin notch",
                "barra \(number(screen.menuBarHeight)) pt",
            ].joined(separator: " · ")
        }
        return (header + lines).joined(separator: "\n")
    }

    // Entero si lo es; si no, con un decimal ("184.5")
    private static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", Double(rounded))
    }

    private static func runningRow(_ inputs: Inputs) -> Row {
        let title = "yabai en marcha"
        guard inputs.yabaiInstalled else {
            return Row(item: .yabaiRunning, status: .missing, title: title, detail: "Primero hay que instalarlo.")
        }
        switch inputs.yabaiError {
        case nil:
            return Row(item: .yabaiRunning, status: .ok, title: title, detail: "Responde a YabaiBar.")
        case .notInstalled?:
            // YabaiBar busca yabai al arrancar: si lo instalaste después, aún mira la ruta de entonces
            return Row(item: .yabaiRunning, status: .warning, title: title, detail: "Reinicia YabaiBar para que encuentre yabai.")
        case .notRunning?:
            return Row(
                item: .yabaiRunning, status: .missing, title: title, detail: "Arráncalo con: \(startYabai)",
                action: .startYabai
            )
        case let error?:
            return Row(item: .yabaiRunning, status: .warning, title: title, detail: error.userMessage)
        }
    }

    private static func shortcutsRow(_ inputs: Inputs) -> Row {
        let title = "Atajos «Ir al escritorio»"
        // ShortcutFocuser solo conoce los atajos de los escritorios 1 a 9
        let desktops = inputs.desktops.isEmpty ? [1, 2] : inputs.desktops.filter { (1...9).contains($0) }
        let missing = desktops.filter { !inputs.desktopsWithShortcut.contains($0) }
        if missing.isEmpty {
            return Row(item: .desktopShortcuts, status: .ok, title: title, detail: "Todos tus escritorios tienen atajo.")
        }
        let instructions = "Actívalos en Ajustes › Teclado › Atajos de teclado › Mission Control."
        if missing.count == desktops.count {
            return Row(
                item: .desktopShortcuts, status: .missing, title: title,
                detail: "Ningún escritorio tiene atajo, así que un clic en una tarjeta no cambia de escritorio. \(instructions)",
                action: .keyboardSettings
            )
        }
        let list = missing.map(String.init).joined(separator: ", ")
        return Row(
            item: .desktopShortcuts, status: .warning, title: title,
            detail: "Sin atajo: \(missing.count == 1 ? "el escritorio" : "los escritorios") \(list). \(instructions)",
            action: .keyboardSettings
        )
    }

    private static func launchRow(_ inputs: Inputs) -> Row {
        let title = "Iniciar al arrancar"
        guard inputs.launchAtLoginAvailable else {
            return Row(item: .launchAtLogin, status: .warning, title: title, detail: "Solo desde /Applications: mueve allí YabaiBar.")
        }
        return Row(
            item: .launchAtLogin, status: inputs.launchAtLogin ? .ok : .warning, title: title,
            detail: inputs.launchAtLogin ? "Se abre sola al iniciar sesión." : "Desactivado: tendrás que abrirla tú.",
            action: .launchAtLoginToggle
        )
    }
}
