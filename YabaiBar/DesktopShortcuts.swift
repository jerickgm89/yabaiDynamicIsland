import CoreGraphics
import Foundation

// Lógica pura de los atajos «Ir al escritorio N» de Mission Control: los ids 118 a 126 de AppleSymbolicHotKeys
// (com.apple.symbolichotkeys), que son los que pulsa ShortcutFocuser. Decide qué escritorios no tienen atajo, cuál
// se les añade (el número con el mismo modificador que los que ya hay, ⌥5 si los demás son ⌥1…⌥4) y cuándo
// preguntar. Mission Control solo tiene atajos para los escritorios 1 a 9.
enum DesktopShortcuts {
    static let desktops = 1...9
    /// La tecla de cada número en el teclado (códigos de tecla de macOS, que no dependen de la distribución)
    static let keyCodes: [Int: Int] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]
    /// ⌃, el de macOS cuando aún no hay ningún atajo de escritorio
    static let defaultModifiers = Int(CGEventFlags.maskControl.rawValue)

    /// Una tecla con sus modificadores (máscara de CGEventFlags, la de AppleSymbolicHotKeys)
    struct Combination: Hashable, Sendable {
        let keyCode: Int
        let modifiers: Int
    }

    /// Un atajo que falta y el que se le añadiría
    struct Proposal: Equatable, Sendable {
        let desktop: Int
        let character: Int
        let keyCode: Int
        let modifiers: Int

        var combination: Combination { Combination(keyCode: keyCode, modifiers: modifiers) }

        /// Como lo escribe macOS, por ejemplo "⌥5"
        var label: String {
            ShortcutFocuser.label(character: character, flags: CGEventFlags(rawValue: UInt64(modifiers)))
        }
    }

    /// Qué hacer cuando cambian los escritorios, y con cuáles
    enum Decision: Equatable {
        case nothing
        /// Añadirlos sin preguntar: el usuario eligió «Añadir siempre»
        case add([Int])
        /// Preguntar antes
        case ask([Int])
    }

    static func id(forDesktop desktop: Int) -> String { String(117 + desktop) }

    /// [carácter, tecla, modificadores] de una entrada activa de AppleSymbolicHotKeys; nil si está desactivada o no
    /// tiene atajo
    static func enabledParameters(_ entry: Any?) -> [Int]? {
        guard let entry = entry as? [String: Any], entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3 else { return nil }
        return parameters
    }

    /// El modificador más usado por los atajos de escritorio que ya hay (en un empate, el del escritorio más bajo);
    /// ⌃ si no hay ninguno
    static func modifiers(in hotkeys: [String: Any]) -> Int {
        var counts: [Int: Int] = [:]
        var first: [Int: Int] = [:]
        for desktop in desktops {
            guard let parameters = enabledParameters(hotkeys[id(forDesktop: desktop)]) else { continue }
            counts[parameters[2], default: 0] += 1
            if first[parameters[2]] == nil { first[parameters[2]] = desktop }
        }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : first[a.key, default: 0] > first[b.key, default: 0]
        }?.key ?? defaultModifiers
    }

    /// Los atajos que faltan para esos escritorios, del 1 al 9 y en orden. Se salta el que chocaría con otro atajo
    /// activo de macOS o con uno de YabaiBar (`reserved`)
    static func proposals(
        for desktops: [Int], in hotkeys: [String: Any], reserved: Set<Combination> = []
    ) -> [Proposal] {
        let modifiers = modifiers(in: hotkeys)
        let candidates = Set(desktops).sorted().compactMap { desktop -> Proposal? in
            guard let keyCode = keyCodes[desktop] else { return nil }
            // El carácter del número: "1" es 49
            return Proposal(desktop: desktop, character: 48 + desktop, keyCode: keyCode, modifiers: modifiers)
        }
        return stillValid(candidates, in: hotkeys, reserved: reserved)
    }

    /// Las que aún se pueden escribir tal cual: el escritorio sigue sin atajo y nadie ha cogido la combinación. Entre
    /// el aviso y la respuesta el usuario puede haber cambiado sus atajos en Ajustes
    static func stillValid(
        _ proposals: [Proposal], in hotkeys: [String: Any], reserved: Set<Combination> = []
    ) -> [Proposal] {
        let used = reserved.union(hotkeys.values.compactMap(enabledParameters).map {
            Combination(keyCode: $0[1], modifiers: $0[2])
        })
        return proposals.filter {
            ShortcutFocuser.shortcut(forDesktop: $0.desktop, in: hotkeys) == nil && !used.contains($0.combination)
        }
    }

    /// AppleSymbolicHotKeys con esos atajos añadidos (o activados, si estaban desactivados). Nunca toca una entrada
    /// que ya tenga un atajo activo, ni ninguna otra
    static func adding(_ proposals: [Proposal], to hotkeys: [String: Any]) -> [String: Any] {
        var result = hotkeys
        for proposal in proposals where ShortcutFocuser.shortcut(forDesktop: proposal.desktop, in: hotkeys) == nil {
            result[id(forDesktop: proposal.desktop)] = [
                "enabled": true,
                "value": ["type": "standard", "parameters": [proposal.character, proposal.keyCode, proposal.modifiers]],
            ] as [String: Any]
        }
        return result
    }

    /// Al cambiar los escritorios (`missing`: los que no tienen atajo):
    /// - con «Añadir siempre», solo los escritorios nuevos, para no volver a activar uno que el usuario quitó a
    ///   propósito; y todos los que falten una sola vez, al activarlo en Ajustes;
    /// - si no, se pregunta por los nuevos;
    /// - nunca en la primera lectura (al arrancar la app), ni por los que el usuario dejó para más tarde.
    static func decision(
        autoAdd: Bool, autoAddTurnedOn: Bool, isFirstLook: Bool, newDesktops: Set<Int>, missing: [Int],
        declined: Set<Int>
    ) -> Decision {
        if autoAddTurnedOn { return missing.isEmpty ? .nothing : .add(missing) }
        guard !isFirstLook else { return .nothing }
        let targets = missing.filter { newDesktops.contains($0) && !declined.contains($0) }
        guard !targets.isEmpty else { return .nothing }
        return autoAdd ? .add(targets) : .ask(targets)
    }

    /// El aviso de la isla cerrada tras añadirlos: «Escritorio 5 · Atajo ⌥5» o «Escritorios 5 y 6 · Atajos ⌥5 y ⌥6»
    static func announcement(for proposals: [Proposal]) -> (title: String, subtitle: String) {
        let desktops = list(proposals.map { String($0.desktop) })
        let labels = list(proposals.map(\.label))
        return proposals.count == 1
            ? ("Escritorio \(desktops)", "Atajo \(labels)")
            : ("Escritorios \(desktops)", "Atajos \(labels)")
    }

    /// "5", "5 y 6", "5, 6 y 7"
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " y " + items[items.count - 1]
    }
}
