import Foundation
import Testing
@testable import YabaiBar

struct DesktopShortcutsTests {
    private static let option = 524288
    private static let control = 262144

    private static func entry(_ character: Int, _ keyCode: Int, _ modifiers: Int, enabled: Bool = true) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": [character, keyCode, modifiers]] as [String: Any]]
    }

    // Los atajos de escritorio de este Mac (com.apple.symbolichotkeys, 2026-11-04): ⌥1 a ⌥4, sin el 5
    private let mine: [String: Any] = [
        "118": entry(49, 18, option), "119": entry(50, 19, option),
        "120": entry(51, 20, option), "121": entry(52, 21, option),
    ]

    @Test func proposesTheMissingDesktopsWithTheSameModifier() {
        let proposals = DesktopShortcuts.proposals(for: [1, 2, 3, 4, 5, 6], in: mine)
        #expect(proposals == [
            DesktopShortcuts.Proposal(desktop: 5, character: 53, keyCode: 23, modifiers: Self.option),
            DesktopShortcuts.Proposal(desktop: 6, character: 54, keyCode: 22, modifiers: Self.option),
        ])
        let labels = proposals.map(\.label)
        #expect(labels == ["⌥5", "⌥6"])
    }

    @Test func withoutDesktopShortcutsItUsesControlLikeMacOS() {
        #expect(DesktopShortcuts.modifiers(in: [:]) == Self.control)
        let labels = DesktopShortcuts.proposals(for: [1, 2], in: [:]).map(\.label)
        #expect(labels == ["⌃1", "⌃2"])
    }

    // Si se mezclan, el modificador más usado; en un empate, el del escritorio más bajo
    @Test func mostUsedModifierWins() {
        var mixed = mine
        mixed["119"] = Self.entry(50, 19, Self.control)
        #expect(DesktopShortcuts.modifiers(in: mixed) == Self.option)
        let tie: [String: Any] = ["119": Self.entry(50, 19, Self.control), "120": Self.entry(51, 20, Self.option)]
        #expect(DesktopShortcuts.modifiers(in: tie) == Self.control)
    }

    // Mission Control no tiene atajos más allá del escritorio 9
    @Test func onlyDesktopsOneToNine() {
        let desktops = DesktopShortcuts.proposals(for: [9, 10, 11, 0], in: mine).map(\.desktop)
        #expect(desktops == [9])
    }

    // ⌥5 ya lo usa otro atajo de macOS: no se propone
    @Test func skipsCombinationsAlreadyInUse() {
        var taken = mine
        taken["60"] = Self.entry(53, 23, Self.option)
        let desktops = DesktopShortcuts.proposals(for: [5, 6], in: taken).map(\.desktop)
        #expect(desktops == [6])
        // Uno desactivado no ocupa la combinación
        taken["60"] = Self.entry(53, 23, Self.option, enabled: false)
        let all = DesktopShortcuts.proposals(for: [5, 6], in: taken).map(\.desktop)
        #expect(all == [5, 6])
    }

    // Un atajo de escritorio desactivado cuenta como que falta, y se vuelve a activar
    @Test func disabledDesktopShortcutsAreProposed() {
        var disabled = mine
        disabled["122"] = Self.entry(53, 23, Self.option, enabled: false)
        let desktops = DesktopShortcuts.proposals(for: [5], in: disabled).map(\.desktop)
        #expect(desktops == [5])
    }

    // Solo añade: las demás entradas quedan igual
    @Test func addingKeepsEverythingElse() {
        var hotkeys = mine
        hotkeys["60"] = Self.entry(32, 49, Self.control, enabled: false)
        let updated = DesktopShortcuts.adding(DesktopShortcuts.proposals(for: [5], in: hotkeys), to: hotkeys)
        #expect(updated.count == hotkeys.count + 1)
        #expect(ShortcutFocuser.shortcut(forDesktop: 5, in: updated)?.label == "⌥5")
        #expect(ShortcutFocuser.shortcut(forDesktop: 1, in: updated)?.label == "⌥1")
        #expect((updated["60"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test func asksOnlyForNewDesktopsAndNeverAtLaunch() {
        func decide(
            auto: Bool = false, turnedOn: Bool = false, first: Bool = false, new: Set<Int>, missing: [Int],
            declined: Set<Int> = []
        ) -> DesktopShortcuts.Decision {
            DesktopShortcuts.decision(
                autoAdd: auto, autoAddTurnedOn: turnedOn, isFirstLook: first, newDesktops: new, missing: missing,
                declined: declined
            )
        }
        // Al arrancar no se pregunta por los que ya faltaban, tampoco con «Añadir siempre»
        #expect(decide(first: true, new: [1, 2, 5], missing: [5]) == .nothing)
        #expect(decide(auto: true, first: true, new: [1, 2, 5], missing: [5]) == .nothing)
        // Un escritorio nuevo sin atajo: se pregunta solo por él, no por el 5 que ya faltaba
        #expect(decide(new: [6], missing: [5, 6]) == .ask([6]))
        // Se quitó uno o los nuevos ya tienen atajo: nada
        #expect(decide(new: [], missing: [5]) == .nothing)
        #expect(decide(new: [7], missing: [5]) == .nothing)
        // «Ahora no» a ese escritorio: no se vuelve a preguntar por él
        #expect(decide(new: [6, 7], missing: [6, 7], declined: [6]) == .ask([7]))
        #expect(decide(new: [6], missing: [6], declined: [6]) == .nothing)
        // Con «Añadir siempre», solo los nuevos: no vuelve a activar uno que el usuario quitó a propósito
        #expect(decide(auto: true, new: [6], missing: [3, 6]) == .add([6]))
        // Al activarlo en Ajustes, todos los que faltan, una vez
        #expect(decide(auto: true, turnedOn: true, new: [], missing: [3, 6]) == .add([3, 6]))
        #expect(decide(auto: true, turnedOn: true, new: [], missing: []) == .nothing)
    }

    // Entre el aviso y la respuesta el usuario pudo poner otro atajo a ese escritorio o usar la combinación: no se
    // pisa nada
    @Test func neverOverwritesAShortcutThatAppearedMeanwhile() {
        let proposals = DesktopShortcuts.proposals(for: [5, 6], in: mine)
        var changed = mine
        changed["122"] = Self.entry(53, 23, Self.control)
        changed["61"] = Self.entry(54, 22, Self.option)
        #expect(DesktopShortcuts.stillValid(proposals, in: changed).isEmpty)
        // Y adding nunca sustituye una entrada activa
        let updated = DesktopShortcuts.adding(proposals, to: changed)
        #expect(ShortcutFocuser.shortcut(forDesktop: 5, in: updated)?.label == "⌃5")
    }

    // Los atajos de YabaiBar (⌥I, ⌥P o el que elija el usuario) tampoco se proponen
    @Test func skipsYabaiBarOwnShortcuts() {
        let reserved: Set<DesktopShortcuts.Combination> = [DesktopShortcuts.Combination(keyCode: 23, modifiers: Self.option)]
        let desktops = DesktopShortcuts.proposals(for: [5, 6], in: mine, reserved: reserved).map(\.desktop)
        #expect(desktops == [6])
        #expect(HotKeyShortcut.defaultToggle.combination == DesktopShortcuts.Combination(keyCode: 34, modifiers: Self.option))
    }

    // El plist real de este Mac, antes de que YabaiBar añadiera nada: 23 entradas, varias sin `value`
    @Test func realPreferencesFromThisMac() throws {
        let data = try Data(contentsOf: Fixture.directory.appending(path: "symbolichotkeys.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let hotkeys = try #require(plist["AppleSymbolicHotKeys"] as? [String: Any])
        #expect(hotkeys.count == 23)
        #expect(DesktopShortcuts.modifiers(in: hotkeys) == Self.option)
        let labels = DesktopShortcuts.proposals(for: Array(1...9), in: hotkeys).map(\.label)
        #expect(labels == ["⌥5", "⌥6", "⌥7", "⌥8", "⌥9"])
        let updated = DesktopShortcuts.adding(DesktopShortcuts.proposals(for: [5], in: hotkeys), to: hotkeys)
        #expect(updated.count == 24)
        #expect(CFPropertyListIsValid(updated as CFDictionary, .binaryFormat_v1_0))
    }

    @Test func announcementForTheClosedIsland() {
        let one = DesktopShortcuts.announcement(for: DesktopShortcuts.proposals(for: [5], in: mine))
        #expect(one.title == "Escritorio 5" && one.subtitle == "Atajo ⌥5")
        let three = DesktopShortcuts.announcement(for: DesktopShortcuts.proposals(for: [5, 6, 7], in: mine))
        #expect(three.title == "Escritorios 5, 6 y 7" && three.subtitle == "Atajos ⌥5, ⌥6 y ⌥7")
    }
}
