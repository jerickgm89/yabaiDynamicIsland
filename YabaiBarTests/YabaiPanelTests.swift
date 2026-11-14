import CoreGraphics
import Foundation
import os
import Testing
@testable import YabaiBar

// El panel de yabai de la pestaña Escritorios (fase 45): las órdenes de cada acción, las ventanas del escritorio activo, dónde está cada
// cosa, lo que recuerda la app y la chuleta de skhd. Nunca se ejecuta el yabai real: el cliente se prueba con un ejecutable falso que apunta
// los argumentos, y los almacenes con falsos.

private func space(_ index: Int, focus: Bool = false, type: String? = "bsp", display: Int = 1) -> YabaiSpace {
    YabaiSpace(id: index, index: index, display: display, windows: [], hasFocus: focus, isVisible: focus, type: type)
}

private func window(
    _ id: Int, space: Int = 1, app: String = "App", title: String? = "Título", focus: Bool = false, minimized: Bool = false,
    hidden: Bool = false, stackIndex: Int? = nil, floating: Bool = false
) -> YabaiWindow {
    YabaiWindow(
        id: id, pid: Int32(id), app: app, space: space, isMinimized: minimized, isHidden: hidden, title: title, hasFocus: focus,
        isFloating: floating, stackIndex: stackIndex
    )
}

// MARK: - Las órdenes

struct YabaiActionTests {
    private func arguments(_ action: YabaiAction) -> [[String]] { action.commands.map(\.arguments) }

    @Test func eachActionIsTheExpectedYabaiCommand() {
        #expect(arguments(.setLayout(.stack)) == [["space", "--layout", "stack"]])
        #expect(arguments(.setLayout(.bsp)) == [["space", "--layout", "bsp"]] && arguments(.setLayout(.float)) == [["space", "--layout", "float"]])
        #expect(arguments(.balance) == [["space", "--balance"]])
        #expect(arguments(.rotate) == [["space", "--rotate", "90"]])
        #expect(arguments(.mirror(.x)) == [["space", "--mirror", "x-axis"]] && arguments(.mirror(.y)) == [["space", "--mirror", "y-axis"]])
        #expect(arguments(.togglePresentation) == [["space", "--toggle", "padding"], ["space", "--toggle", "gap"]])
        #expect(arguments(.focusWindow(42)) == [["window", "--focus", "42"]])
        #expect(arguments(.stackStep(forward: true)) == [["window", "--focus", "stack.next"]])
        #expect(arguments(.stackStep(forward: false)) == [["window", "--focus", "stack.prev"]])
        #expect(arguments(.stackEdge(first: true)) == [["window", "--focus", "stack.first"]])
        #expect(arguments(.toggleFloat) == [["window", "--toggle", "float"]])
        #expect(arguments(.toggleZoomParent) == [["window", "--toggle", "zoom-parent"]])
        #expect(arguments(.toggleZoomFullscreen) == [["window", "--toggle", "zoom-fullscreen"]])
        #expect(arguments(.toggleSplit) == [["window", "--toggle", "split"]])
        #expect(arguments(.swapWithLargest) == [["window", "--swap", "largest"]])
        #expect(arguments(.toggleSticky) == [["window", "--toggle", "sticky"]])
        #expect(arguments(.setSubLayer(.above)) == [["window", "--sub-layer", "above"]])
        #expect(arguments(.setSubLayer(.auto)) == [["window", "--sub-layer", "auto"]])
        #expect(arguments(.moveWindow(id: 7, toSpace: 3)) == [["window", "7", "--space", "3"]])
        #expect(arguments(.createSpace) == [["space", "--create"]])
        #expect(arguments(.destroySpace(4)) == [["space", "--destroy", "4"]])
        #expect(arguments(.moveSpace(forward: true)) == [["space", "--move", "next"]])
        #expect(arguments(.moveSpace(forward: false)) == [["space", "--move", "prev"]])
        #expect(arguments(.focusSpace(5)) == [["space", "--focus", "5"]])
        #expect(arguments(.configLayout(space: 2, layout: .stack)) == [["space", "2", "--layout", "stack"]])
    }

    @Test func theFloatRuleReplacesTheOldOneAndAppliesToExistingWindows() {
        let commands = YabaiAction.addFloatRule(app: "Notas").commands
        let label = YabaiRules.label(for: "Notas")
        #expect(commands.map(\.arguments) == [
            ["rule", "--remove", label], ["rule", "--add", "label=\(label)", "app=\(YabaiRules.pattern(for: "Notas"))", "manage=off"], ["rule", "--apply", label],
        ])
        // Quitar y aplicar pueden fallar sin que importe; añadir, no
        #expect(commands.map(\.optional) == [true, false, true])
        #expect(YabaiAction.removeFloatRule(app: "Notas").commands.map(\.arguments) == [["rule", "--remove", label]])
    }

    @Test func theScriptingAdditionIsOnlyAskedWhereYabaiNeedsIt() {
        let required: [YabaiAction] = [.toggleSticky, .setSubLayer(.above), .createSpace, .destroySpace(1), .moveSpace(forward: true), .focusSpace(2)]
        for action in required { #expect(action.scriptingAddition == .required, "\(action)") }
        #expect(YabaiAction.moveWindow(id: 1, toSpace: 2).scriptingAddition == .maybe)
        let free: [YabaiAction] = [.setLayout(.bsp), .balance, .rotate, .mirror(.x), .togglePresentation, .focusWindow(1), .stackStep(forward: true), .toggleFloat, .toggleZoomParent, .toggleZoomFullscreen, .toggleSplit, .swapWithLargest, .addFloatRule(app: "A"), .configLayout(space: 1, layout: .bsp)]
        for action in free { #expect(action.scriptingAddition == .none, "\(action)") }
    }

    @Test func theStackWrapsAroundWithItsFallback() {
        #expect(YabaiAction.stackStep(forward: true).fallback == .stackEdge(first: true))
        #expect(YabaiAction.stackStep(forward: false).fallback == .stackEdge(first: false))
        #expect(YabaiAction.balance.fallback == nil)
    }

    @Test func everyActionHasATitleAndWorkspaceChangesAreFlagged() {
        #expect(YabaiAction.moveWindow(id: 1, toSpace: 3).title.contains("3") && YabaiAction.destroySpace(2).title.contains("2"))
        #expect(YabaiAction.balance.changesWorkspace && YabaiAction.focusSpace(1).changesWorkspace)
        // Añadir una regla la aplica a las ventanas que hay: cambia lo que se ve. Lo que solo se recuerda, no
        #expect(YabaiAction.addFloatRule(app: "A").changesWorkspace)
        #expect(!YabaiAction.removeFloatRule(app: "A").changesWorkspace && !YabaiAction.configLayout(space: 1, layout: .bsp).changesWorkspace)
    }

    // MARK: Reglas

    @Test func aRuleLabelIsSafeAndStable() {
        let label = YabaiRules.label(for: "Google Chrome (beta)")
        #expect(label.hasPrefix("yb_float_") && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        #expect(label == YabaiRules.label(for: "Google Chrome (beta)"))
        // Nombres parecidos no chocan, aunque se parezcan tras limpiarlos
        #expect(YabaiRules.label(for: "App 1") != YabaiRules.label(for: "App_1") && YabaiRules.label(for: "Ñandú") != YabaiRules.label(for: "Nandu"))
    }

    @Test func theRulePatternMatchesTheExactAppName() {
        // El nombre entre las marcas de dirección que yabai a veces le pone (opcionales)
        let marks = "[\u{200E}\u{200F}]*"
        #expect(YabaiRules.pattern(for: "Notas") == "^\(marks)Notas\(marks)$")
        #expect(YabaiRules.pattern(for: "A.B (x)+") == "^\(marks)A\\.B \\(x\\)\\+\(marks)$")
        #expect(YabaiRules.pattern(for: "a|b") == "^\(marks)a\\|b\(marks)$")
        // La expresión de verdad (POSIX extendida, como la que usa yabai con `regcomp`) casa con el nombre y con nada más
        #expect(Self.posixMatches(YabaiRules.pattern(for: "C++ [dev]"), "C++ [dev]"))
        #expect(!Self.posixMatches(YabaiRules.pattern(for: "C++ [dev]"), "C++ [dev] extra"))
        #expect(!Self.posixMatches(YabaiRules.pattern(for: "C++ [dev]"), "C [dev]"))
        for name in ["a|b", "Foo{2}", "a\\b", "$x", "^y", "q?", "Ñandú", "App (1)", "a.b"] {
            #expect(Self.posixMatches(YabaiRules.pattern(for: name), name), "\(name)")
        }
        #expect(!Self.posixMatches(YabaiRules.pattern(for: "a.b"), "axb") && !Self.posixMatches(YabaiRules.pattern(for: "a|b"), "a"))
    }

    // yabai antepone U+200E a «WhatsApp»: la regla tiene que casar con el nombre real aunque se guarde sin la marca
    @Test func theRuleMatchesNamesWithInvisibleDirectionMarks() {
        let pattern = YabaiRules.pattern(for: "WhatsApp")
        #expect(Self.posixMatches(pattern, "WhatsApp") && Self.posixMatches(pattern, "\u{200E}WhatsApp"))
        #expect(Self.posixMatches(pattern, "\u{200F}WhatsApp\u{200E}") && !Self.posixMatches(pattern, "\u{200E}WhatsAppX"))
        #expect(!Self.posixMatches(pattern, "\u{200E}Whats App"))
    }

    private static func posixMatches(_ pattern: String, _ text: String) -> Bool {
        var regex = regex_t()
        guard regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) == 0 else { return false }
        defer { regfree(&regex) }
        return regexec(&regex, text, 0, nil, 0) == 0
    }

    @Test func anAppNameIsCleanedOrRefused() {
        #expect(YabaiRules.clean("  Notas ") == "Notas" && YabaiRules.clean("\u{200E}WhatsApp") == "WhatsApp")
        #expect(YabaiRules.clean("") == nil && YabaiRules.clean("   ") == nil)
        #expect(YabaiRules.clean("dos\nlíneas") == nil && YabaiRules.clean("con\u{7}control") == nil)
        #expect(YabaiRules.clean(String(repeating: "a", count: 129)) == nil)
    }

    // MARK: Distribución recordada

    @Test func onlyTheLayoutsThatChangedAreReapplied() {
        let spaces = [
            SpaceSummary(index: 1, isFocused: true, apps: [], layout: .bsp), SpaceSummary(index: 2, isFocused: false, apps: [], layout: .bsp),
            SpaceSummary(index: 3, isFocused: false, apps: [], layout: .stack),
        ]
        let remembered: [Int: YabaiLayout] = [1: .bsp, 2: .stack, 3: .stack, 9: .float]
        // El 1 y el 3 ya coinciden; el 9 no existe
        #expect(LayoutMemory.reapply(remembered: remembered, current: spaces) == [.configLayout(space: 2, layout: .stack)])
        #expect(LayoutMemory.reapply(remembered: [:], current: spaces).isEmpty)
        // Si yabai no dijo la distribución, no se toca
        let unknown = [SpaceSummary(index: 1, isFocused: true, apps: [], layout: nil)]
        #expect(LayoutMemory.reapply(remembered: [1: .stack], current: unknown).isEmpty)
    }

    // Quitar o mover un escritorio cambia los números de los demás: lo recordado va con ellos
    @Test func rememberedLayoutsFollowTheirDesktopsWhenTheyShift() {
        let layouts: [Int: YabaiLayout] = [1: .bsp, 2: .stack, 4: .float]
        #expect(LayoutMemory.afterDestroying(1, in: layouts) == [1: .stack, 3: .float])
        #expect(LayoutMemory.afterDestroying(3, in: layouts) == [1: .bsp, 2: .stack, 3: .float])
        #expect(LayoutMemory.afterDestroying(2, in: layouts) == [1: .bsp, 3: .float])
        #expect(LayoutMemory.afterMoving(2, forward: true, in: layouts) == [1: .bsp, 3: .stack, 4: .float])
        #expect(LayoutMemory.afterMoving(2, forward: false, in: layouts) == [1: .stack, 2: .bsp, 4: .float])
        // Con un vecino sin nada recordado, lo recordado se va con el escritorio
        #expect(LayoutMemory.afterMoving(4, forward: true, in: layouts) == [1: .bsp, 2: .stack, 5: .float])
        // Mover el primero hacia atrás no hace nada
        #expect(LayoutMemory.afterMoving(1, forward: false, in: layouts) == layouts)
    }

    @Test func rememberedLayoutsSurviveStorage() {
        let stored = LayoutMemory.encode([1: .bsp, 4: .float])
        #expect(stored == ["1": "bsp", "4": "float"])
        #expect(LayoutMemory.decode(stored) == [1: .bsp, 4: .float])
        // Lo que no vale se descarta
        #expect(LayoutMemory.decode(["x": "bsp", "2": "raro", "0": "bsp", "3": "stack", "99999": "bsp"]) == [3: .stack])
    }

    // MARK: La scripting addition

    @Test func theUserCanAssumeTheScriptingAddition() throws {
        let defaults = try #require(UserDefaults(suiteName: "yabai-sa-\(UUID().uuidString)"))
        #expect(!ScriptingAddition.isLoaded(user: "ana", exists: { _ in false }, defaults: defaults))
        defaults.set(true, forKey: ScriptingAddition.overrideKey)
        #expect(ScriptingAddition.isLoaded(user: "ana", exists: { _ in false }, defaults: defaults))
    }

    @Test func theScriptingAdditionIsSeenByItsSocket() {
        #expect(ScriptingAddition.socketPath(user: "ana") == "/tmp/yabai-sa_ana.socket")
        #expect(ScriptingAddition.isLoaded(user: "ana", exists: { $0 == "/tmp/yabai-sa_ana.socket" }))
        #expect(!ScriptingAddition.isLoaded(user: "ana", exists: { _ in false }))
        #expect(!ScriptingAddition.isLoaded(user: "ana", exists: { $0.contains("otro") }))
    }
}

// MARK: - Las ventanas del escritorio activo

struct DesktopWindowsTests {
    @Test func onlyTheActiveSpaceWindowsAreShown() throws {
        let result = try #require(DesktopWindows.make(
            spaces: [space(1), space(2, focus: true), space(3)],
            windows: [window(10, space: 1), window(20, space: 2), window(21, space: 2, minimized: true), window(22, space: 2, hidden: true), window(30, space: 3)]
        ))
        #expect(result.spaceIndex == 2 && result.windows.map(\.id) == [20])
    }

    // La propia isla y lo que no es una ventana de verdad (sin referencia de accesibilidad) no salen: no se pueden enfocar ni mover
    @Test func ownWindowsAndNonWindowsAreLeftOut() throws {
        var notAWindow = window(20, space: 1)
        notAWindow.hasAxReference = false
        var real = window(21, space: 1)
        real.hasAxReference = true
        let own = YabaiWindow(id: 22, pid: 999, app: "YabaiBar", space: 1, isMinimized: false, isHidden: false)
        let result = try #require(DesktopWindows.make(
            spaces: [space(1, focus: true)], windows: [notAWindow, real, own, window(23, space: 1)], excludingPID: 999
        ))
        #expect(result.windows.map(\.id) == [21, 23])
    }

    @Test func noFocusedSpaceMeansNothing() {
        #expect(DesktopWindows.make(spaces: [space(1), space(2)], windows: [window(1)]) == nil)
        #expect(DesktopWindows.make(spaces: [], windows: []) == nil)
    }

    @Test func theLayoutComesFromYabai() throws {
        #expect(try #require(DesktopWindows.make(spaces: [space(1, focus: true, type: "stack")], windows: [])).layout == .stack)
        #expect(try #require(DesktopWindows.make(spaces: [space(1, focus: true, type: nil)], windows: [])).layout == nil)
        #expect(try #require(DesktopWindows.make(spaces: [space(1, focus: true, type: "raro")], windows: [])).layout == nil)
    }

    // En pila, por su posición en la pila; si no, por identificador, que no cambia
    @Test func windowsAreOrderedByStackPositionOrId() throws {
        let windows = [window(30, stackIndex: 2), window(10, stackIndex: 3), window(20, stackIndex: 1)]
        let stacked = try #require(DesktopWindows.make(spaces: [space(1, focus: true, type: "stack")], windows: windows))
        #expect(stacked.windows.map(\.id) == [20, 30, 10])
        let tiled = try #require(DesktopWindows.make(spaces: [space(1, focus: true, type: "bsp")], windows: windows))
        #expect(tiled.windows.map(\.id) == [10, 20, 30])
    }

    @Test func aTitleIsCleanedShortenedOrReplacedByTheApp() throws {
        #expect(DesktopWindows.cleanTitle("  hola\nmundo\t!  ", fallback: "App") == "hola mundo !")
        #expect(DesktopWindows.cleanTitle("", fallback: "Notas") == "Notas" && DesktopWindows.cleanTitle(nil, fallback: "Notas") == "Notas")
        #expect(DesktopWindows.cleanTitle("\u{7}\u{200E}", fallback: "Notas") == "Notas")
        let long = DesktopWindows.cleanTitle(String(repeating: "a", count: 500), fallback: "App")
        #expect(long.count == DesktopWindows.maxTitleLength && long.hasSuffix("…"))
        // En la ventana, el nombre de la app sin las marcas invisibles de yabai
        let result = try #require(DesktopWindows.make(spaces: [space(1, focus: true)], windows: [window(1, app: "\u{200E}WhatsApp", title: "")]))
        #expect(result.windows.first?.app == "WhatsApp" && result.windows.first?.title == "WhatsApp")
    }

    @Test func theNewFieldsDecodeFromRealOutputAndOldFixturesStillWork() throws {
        let real = try JSONDecoder().decode([YabaiWindow].self, from: try Fixture.data("windows"))
        #expect(!real.isEmpty && real.contains { $0.hasFocus == true } && real.allSatisfy { $0.isFloating != nil && $0.subLayer != nil })
        let spaces = try JSONDecoder().decode([YabaiSpace].self, from: try Fixture.data("spaces"))
        #expect(spaces.allSatisfy { $0.type == "bsp" })
        // Sin los campos nuevos (un yabai viejo), sigue decodificando
        let old = #"[{"id":1,"pid":2,"app":"A","space":1,"is-minimized":false,"is-hidden":false}]"#
        #expect(try JSONDecoder().decode([YabaiWindow].self, from: Data(old.utf8)).first?.title == nil)
    }

    @Test func theCardKnowsItsLayout() {
        let summaries = SpaceGrouper.group(spaces: [space(1, focus: true, type: "stack"), space(2, type: "float"), space(3, type: nil)], windows: [])
        #expect(summaries.map(\.layout) == [.stack, .float, nil])
    }
}

// MARK: - Soltar una ventana sobre una tarjeta

struct DesktopDropTests {
    private func card(_ index: Int, focused: Bool = false, fullscreen: Bool = false) -> SpaceSummary {
        SpaceSummary(index: index, isFocused: focused, apps: [], isFullscreen: fullscreen)
    }

    @Test func aWindowDroppedOnAnotherDesktopMovesThere() throws {
        let target = try #require(DesktopDrop.target(pressed: .window(7), under: nil, space: card(3)))
        #expect(target.window == 7 && target.space == 3)
    }

    @Test func nothingMovesWithoutADeliberateDropOnAnotherDesktop() {
        // En el mismo escritorio (la tarjeta activa), sobre ningún escritorio o sobre un escritorio a pantalla completa
        #expect(DesktopDrop.target(pressed: .window(7), under: nil, space: card(2, focused: true)) == nil)
        #expect(DesktopDrop.target(pressed: .window(7), under: nil, space: nil) == nil)
        #expect(DesktopDrop.target(pressed: .window(7), under: nil, space: card(3, fullscreen: true)) == nil)
        // Soltar sobre el mismo chip (un clic) enfoca, no mueve
        #expect(DesktopDrop.target(pressed: .window(7), under: .window(7), space: card(3)) == nil)
        // Los botones no se sueltan sobre tarjetas
        #expect(DesktopDrop.target(pressed: .balance, under: nil, space: card(3)) == nil)
    }
}

// MARK: - Los controles

struct DesktopControlTests {
    private func snapshot(
        focused: Bool = true, layout: YabaiLayout? = .bsp, floating: Bool = false, above: Bool = false, apps: [String] = [],
        zoomParent: Bool = false, zoomFullscreen: Bool = false, remembered: [Int: YabaiLayout] = [:], presentation: Set<Int> = []
    ) -> DesktopControlSnapshot {
        DesktopControlSnapshot(
            spaceIndex: 2, layout: layout,
            windows: [
                DesktopWindow(
                    id: 7, pid: 1, app: "Notas", title: "Ideas", isFocused: focused, isFloating: floating, isSticky: false,
                    hasParentZoom: zoomParent, hasFullscreenZoom: zoomFullscreen, stackIndex: nil, subLayer: above ? "above" : "normal"
                ),
            ],
            floatApps: apps, rememberedLayouts: remembered, presentationSpaces: presentation
        )
    }

    @Test func eachControlAsksForItsAction() {
        let on = snapshot()
        #expect(DesktopControl.window(7).action(snapshot: on) == .focusWindow(7))
        #expect(DesktopControl.layout(.stack).action(snapshot: on) == .setLayout(.stack))
        #expect(DesktopControl.balance.action(snapshot: on) == .balance && DesktopControl.rotate.action(snapshot: on) == .rotate)
        #expect(DesktopControl.mirror(.y).action(snapshot: on) == .mirror(.y) && DesktopControl.presentation.action(snapshot: on) == .togglePresentation)
        #expect(DesktopControl.toggleFloat.action(snapshot: on) == .toggleFloat && DesktopControl.split.action(snapshot: on) == .toggleSplit)
        #expect(DesktopControl.makeMain.action(snapshot: on) == .swapWithLargest && DesktopControl.sticky.action(snapshot: on) == .toggleSticky)
        #expect(DesktopControl.newSpace.action(snapshot: on) == .createSpace && DesktopControl.removeSpace.action(snapshot: on) == .destroySpace(2))
        #expect(DesktopControl.moveSpace(forward: true).action(snapshot: on) == .moveSpace(forward: true))
        #expect(DesktopControl.stack(forward: false).action(snapshot: on) == .stackStep(forward: false))
        // «Recordar» y la chuleta no son órdenes de yabai
        #expect(DesktopControl.rememberLayout.action(snapshot: on) == nil && DesktopControl.skhd.action(snapshot: on) == nil)
    }

    // Un solo botón de zoom: sin zoom → al padre → a todo el escritorio → sin zoom
    @Test func theZoomButtonCyclesThroughTheZoomModes() {
        #expect(DesktopControl.zoom.action(snapshot: snapshot()) == .toggleZoomParent)
        #expect(DesktopControl.zoom.action(snapshot: snapshot(zoomParent: true)) == .switchZoomToFullscreen)
        #expect(DesktopControl.zoom.action(snapshot: snapshot(zoomFullscreen: true)) == .toggleZoomFullscreen)
        #expect(YabaiAction.switchZoomToFullscreen.commands.map(\.arguments) == [["window", "--toggle", "zoom-parent"], ["window", "--toggle", "zoom-fullscreen"]])
        #expect(DesktopControl.zoom.title(snapshot: snapshot()) == "Zoom al padre")
        #expect(DesktopControl.zoom.title(snapshot: snapshot(zoomParent: true)) == "Zoom a todo el escritorio")
        #expect(DesktopControl.zoom.title(snapshot: snapshot(zoomFullscreen: true)) == "Quitar el zoom")
    }

    // Sin ventana enfocada, lo que es de ella no hace nada
    @Test func windowControlsNeedAFocusedWindow() {
        let none = snapshot(focused: false)
        for control in [DesktopControl.toggleFloat, .zoom, .split, .makeMain, .sticky, .above, .floatApp] {
            #expect(control.action(snapshot: none) == nil && control.needsFocusedWindow, "\(control)")
        }
        // Lo del escritorio no la necesita
        #expect(DesktopControl.balance.action(snapshot: none) == .balance && !DesktopControl.balance.needsFocusedWindow)
        // Sin escritorio activo no se puede quitar
        #expect(DesktopControl.removeSpace.action(snapshot: DesktopControlSnapshot()) == nil)
    }

    @Test func aboveTogglesAndFloatAppAddsOrRemoves() {
        #expect(DesktopControl.above.action(snapshot: snapshot(above: false)) == .setSubLayer(.above))
        #expect(DesktopControl.above.action(snapshot: snapshot(above: true)) == .setSubLayer(.auto))
        #expect(DesktopControl.floatApp.action(snapshot: snapshot(apps: [])) == .addFloatRule(app: "Notas"))
        #expect(DesktopControl.floatApp.action(snapshot: snapshot(apps: ["Notas"])) == .removeFloatRule(app: "Notas"))
    }

    @Test func buttonsLightUpWithWhatIsTrue() {
        #expect(DesktopControl.layout(.bsp).isOn(snapshot: snapshot(layout: .bsp)) && !DesktopControl.layout(.stack).isOn(snapshot: snapshot(layout: .bsp)))
        #expect(DesktopControl.toggleFloat.isOn(snapshot: snapshot(floating: true)) && !DesktopControl.toggleFloat.isOn(snapshot: snapshot()))
        #expect(DesktopControl.above.isOn(snapshot: snapshot(above: true)) && DesktopControl.floatApp.isOn(snapshot: snapshot(apps: ["Notas"])))
        #expect(DesktopControl.zoom.isOn(snapshot: snapshot(zoomParent: true)) && DesktopControl.zoom.isOn(snapshot: snapshot(zoomFullscreen: true)))
        #expect(!DesktopControl.zoom.isOn(snapshot: snapshot()))
        #expect(DesktopControl.window(7).isOn(snapshot: snapshot()) && !DesktopControl.window(8).isOn(snapshot: snapshot()))
        #expect(!DesktopControl.balance.isOn(snapshot: snapshot()))
        // «Recordar en el N» y la presentación miran el escritorio activo (el 2)
        #expect(DesktopControl.rememberLayout.isOn(snapshot: snapshot(remembered: [2: .stack])) && !DesktopControl.rememberLayout.isOn(snapshot: snapshot(remembered: [1: .stack])))
        #expect(DesktopControl.presentation.isOn(snapshot: snapshot(presentation: [2])) && !DesktopControl.presentation.isOn(snapshot: snapshot()))
    }

    @Test func everyButtonHasItsSymbolOrItsTextAndATitle() {
        for entry in DesktopPanelLayout.frames(width: 740, windowCount: 0).buttons {
            #expect(entry.control.symbol != nil || entry.control.label != nil, "\(entry.control)")
            #expect(!entry.control.title().isEmpty, "\(entry.control)")
        }
        // Los de texto, como en el diseño
        #expect(DesktopControl.layout(.bsp).label == "BSP" && DesktopControl.layout(.stack).label == "Pila" && DesktopControl.layout(.float).label == "Flotante")
        #expect(DesktopControl.toggleFloat.label == "Flotante" && DesktopControl.zoom.label == "Zoom" && DesktopControl.split.label == "Dividir")
        #expect(DesktopControl.makeMain.label == "Principal" && DesktopControl.floatApp.label == "Siempre flotante" && DesktopControl.skhd.label == "Atajos de skhd")
        #expect(DesktopControl.window(1).symbol == nil)
        for control in [DesktopControl.sticky, .above, .newSpace, .removeSpace, .moveSpace(forward: true)] { #expect(control.scriptingAddition == .required) }
        #expect(DesktopControl.balance.scriptingAddition == .none && DesktopControl.layout(.bsp).scriptingAddition == .none)
    }

    // Lo que se ve atenuado: lo que necesita la scripting addition sin ella, lo de una ventana sin enfocada y la pila fuera de una pila
    @Test func dimmedButtonsAreTheOnesThatWouldNotWork() {
        let plain = snapshot(layout: .bsp)
        #expect(DesktopControl.sticky.isDimmed(snapshot: plain) && DesktopControl.newSpace.isDimmed(snapshot: plain))
        var withSA = plain
        withSA.scriptingAddition = true
        #expect(!DesktopControl.sticky.isDimmed(snapshot: withSA) && !DesktopControl.newSpace.isDimmed(snapshot: withSA))
        #expect(DesktopControl.zoom.isDimmed(snapshot: snapshot(focused: false)) && !DesktopControl.zoom.isDimmed(snapshot: plain))
        #expect(DesktopControl.stack(forward: true).isDimmed(snapshot: plain) && !DesktopControl.stack(forward: true).isDimmed(snapshot: snapshot(layout: .stack)))
        #expect(!DesktopControl.balance.isDimmed(snapshot: plain))
    }

    @Test func aWindowTitleInTheHeaderNamesTheAppAndTheWindow() {
        #expect(DesktopControl.window(7).title(snapshot: snapshot()) == "Notas — Ideas")
        #expect(DesktopControl.window(99).title(snapshot: snapshot()) == "Enfocar la ventana")
    }

    @Test func aFailureIsExplainedWithoutLeakingMore() {
        let sa = DesktopControlText.needsScriptingAddition
        #expect(DesktopControlText.message(for: .notRunning, action: .balance, scriptingAddition: true) == "yabai no responde")
        #expect(DesktopControlText.message(for: .commandFailed(command: "x", stderr: "could not connect to scripting-addition"), action: .createSpace, scriptingAddition: true) == sa)
        #expect(DesktopControlText.message(for: .commandFailed(command: "x", stderr: ""), action: .createSpace, scriptingAddition: false) == sa)
        // Sin explicación y con la scripting addition cargada, no se le echa la culpa
        #expect(DesktopControlText.message(for: .commandFailed(command: "x", stderr: ""), action: .createSpace, scriptingAddition: true) == "yabai no pudo hacerlo")
        let long = String(repeating: "x", count: 300)
        #expect(DesktopControlText.message(for: .commandFailed(command: "x", stderr: long), action: .balance, scriptingAddition: true).count == 70)
        #expect(DesktopControlText.message(for: .timedOut(command: "x"), action: .balance, scriptingAddition: true) == "yabai tardó demasiado")
    }
}

// MARK: - Dónde está cada cosa (el diseño del lienzo: «Escritorios con todas las propuestas de yabai»)

struct DesktopPanelLayoutTests {
    private let width: CGFloat = 740

    // Las medidas del diseño: dos filas de secciones de 82 y 62 pt, y en ellas 390 + 340 y 390 + 150 + 180 pt
    @Test func theFiveSectionsAreTheOnesOfTheDesign() {
        let frames = DesktopPanelLayout.frames(width: width, windowCount: 3)
        #expect(frames.windowsSection == CGRect(x: 0, y: 0, width: 390, height: 82))
        #expect(frames.layoutSection == CGRect(x: 400, y: 0, width: 340, height: 82))
        #expect(frames.focusedSection == CGRect(x: 0, y: 92, width: 390, height: 62))
        #expect(frames.spaceSection == CGRect(x: 400, y: 92, width: 150, height: 62))
        #expect(frames.statusSection == CGRect(x: 560, y: 92, width: 180, height: 62))
        #expect(DesktopPanelLayout.height == 154 && DesktopPanelLayout.minWidth == width)
    }

    @Test func sectionsNeverOverlapOrLeaveThePanelAtAnyWidth() {
        for panelWidth in stride(from: 400.0, through: 1000.0, by: 20.0) {
            let sections = DesktopPanelLayout.sections(width: panelWidth)
            let bounds = CGRect(x: 0, y: 0, width: panelWidth, height: DesktopPanelLayout.height)
            for (index, rect) in sections.enumerated() {
                #expect(rect.width >= 0 && rect.height > 0 && bounds.contains(rect), "\(panelWidth) pt, sección \(index)")
                for other in sections[(index + 1)...] { #expect(!rect.intersects(other.insetBy(dx: 0.01, dy: 0.01)), "\(panelWidth) pt") }
            }
        }
    }

    @Test func everyButtonIsInsideItsSectionAndDoesNotOverlapAnother() {
        for panelWidth in [600.0, 740, 900] {
            let frames = DesktopPanelLayout.frames(width: panelWidth, windowCount: 4)
            let sections = [frames.windowsSection, frames.layoutSection, frames.focusedSection, frames.spaceSection, frames.statusSection]
            let buttons = frames.buttons
            for (index, button) in buttons.enumerated() {
                #expect(button.frame.width >= 0 && button.frame.height > 0, "\(button.control)")
                #expect(sections.contains { $0.insetBy(dx: -1, dy: -3).contains(button.frame) }, "\(panelWidth) pt, \(button.control)")
                for other in buttons[(index + 1)...] { #expect(!button.frame.intersects(other.frame.insetBy(dx: 0.01, dy: 0.01)), "\(button.control) con \(other.control)") }
            }
            for chip in frames.chips { #expect(frames.windowsSection.contains(chip)) }
        }
    }

    @Test func theControlsAreInTheSectionsOfTheDesign() {
        let frames = DesktopPanelLayout.frames(width: width, windowCount: 3)
        func section(of control: DesktopControl) -> CGRect? {
            let sections = [frames.windowsSection, frames.layoutSection, frames.focusedSection, frames.spaceSection, frames.statusSection]
            guard let button = frames.buttons.first(where: { $0.control == control }) else { return nil }
            return sections.first { $0.insetBy(dx: -1, dy: -3).contains(button.frame) }
        }
        #expect(section(of: .stack(forward: true)) == frames.windowsSection)
        for control in [DesktopControl.layout(.bsp), .layout(.stack), .layout(.float), .balance, .rotate, .mirror(.x), .mirror(.y), .rememberLayout] {
            #expect(section(of: control) == frames.layoutSection, "\(control)")
        }
        for control in [DesktopControl.toggleFloat, .zoom, .split, .makeMain, .floatApp, .sticky, .above] {
            #expect(section(of: control) == frames.focusedSection, "\(control)")
        }
        for control in [DesktopControl.presentation, .removeSpace, .moveSpace(forward: false), .moveSpace(forward: true)] {
            #expect(section(of: control) == frames.spaceSection, "\(control)")
        }
        #expect(section(of: .skhd) == frames.statusSection)
        // Segmentado: BSP, Pila y Flotante dentro de su pista, y los cuatro botones de icono a su derecha, de 30 × 34
        #expect(frames.segments.map(\.control) == [.layout(.bsp), .layout(.stack), .layout(.float)])
        #expect(frames.layoutIcons.map(\.control) == [.balance, .rotate, .mirror(.x), .mirror(.y)])
        #expect(frames.layoutIcons.allSatisfy { $0.frame.size == CGSize(width: 30, height: 34) && $0.frame.minX >= frames.segmentedTrack.maxX })
        #expect(frames.segmentedTrack.height == 34 && frames.focusedText.allSatisfy { $0.frame.height == 26 })
        #expect(frames.focusedText.map(\.control) == [.toggleFloat, .zoom, .split, .makeMain, .floatApp])
    }

    // Como un `flex: 1`: las ventanas se reparten el ancho; con más de las que caben, la última casilla es el «+n»
    @Test func windowsShareTheRowAndTheOverflowTakesALastSlot() {
        let three = DesktopPanelLayout.frames(width: width, windowCount: 3)
        #expect(DesktopPanelLayout.chipCapacity(sectionWidth: three.windowsSection.width) == 3)
        #expect(three.chips.count == 3 && three.overflow == nil)
        #expect(Set(three.chips.map(\.width)).count == 1 && three.chips.allSatisfy { $0.height == 34 })
        let one = DesktopPanelLayout.frames(width: width, windowCount: 1)
        #expect(one.chips.count == 1 && one.chips[0].width > three.chips[0].width)
        let six = DesktopPanelLayout.frames(width: width, windowCount: 6)
        #expect(six.chips.count == 2 && six.overflow != nil && six.overflow!.width == DesktopPanelLayout.overflowWidth)
        #expect(six.chips.allSatisfy { $0.maxX <= six.overflow!.minX })
        #expect(DesktopPanelLayout.visibleChips(windowCount: 9, capacity: 1) == 0 && DesktopPanelLayout.visibleChips(windowCount: 2, capacity: 3) == 2)
        #expect(DesktopPanelLayout.frames(width: width, windowCount: 0).chips.isEmpty)
    }

    @Test func clicksResolveWindowsAndButtons() throws {
        let ids = [10, 20, 30]
        let frames = DesktopPanelLayout.frames(width: width, windowCount: 3)
        func control(_ point: CGPoint, ids: [Int] = ids) -> DesktopControl? { DesktopPanelLayout.control(at: point, windowIDs: ids, width: width) }
        func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        #expect(control(center(frames.chips[1])) == .window(20))
        for button in frames.buttons { #expect(control(center(button.frame)) == button.control, "\(button.control)") }
        // Las cabeceras, los huecos y fuera del panel no responden
        #expect(control(CGPoint(x: 30, y: 8)) == nil && control(CGPoint(x: -5, y: -5)) == nil && control(CGPoint(x: width + 5, y: 20)) == nil)
        // Con más ventanas de las que se dibujan, solo responden las que se ven
        let many = DesktopPanelLayout.frames(width: width, windowCount: 6)
        #expect(control(center(many.chips[1]), ids: [1, 2, 3, 4, 5, 6]) == .window(2))
        if let overflow = many.overflow { #expect(control(center(overflow), ids: [1, 2, 3, 4, 5, 6]) == nil) }
    }

    private func layout(_ tab: IslandTab, panel: Bool, spaces: Int = 4, topHeight: CGFloat = 38) -> IslandExpandedLayout {
        IslandExpandedLayout(
            spaces: (1...spaces).map { SpaceSummary(index: $0, isFocused: $0 == 1, apps: []) }, minBodyWidth: 396, maxBodyWidth: 1958,
            topHeight: topHeight, tab: tab, tabs: IslandTab.allCases, developerModules: ModuleID.modules(of: .developer), hasMedia: true,
            hasKeepAwake: true, hasPomodoro: true, hasSettingsButton: true, hasDesktopPanel: panel
        )
    }

    // El diseño: con cinco escritorios y la tarjeta «+», el cuerpo mide 768 × 294 con el notch de 38 pt
    @Test func theDesktopsTabMeasuresWhatTheDesignSays() {
        let design = layout(.desktops, panel: true, spaces: 5)
        #expect(design.bodyWidth == 768 && design.height == 294)
        #expect(design.cardWidth == IslandExpandedLayout.cardWidth)
        // Con menos escritorios, el cuerpo no baja del ancho del panel
        #expect(layout(.desktops, panel: true, spaces: 2).bodyWidth >= 768 - 28 + 28)
        // Sin el panel, como antes (solo las tarjetas)
        #expect(layout(.desktops, panel: false, spaces: 2).height == 38 + IslandExpandedLayout.gapBelowNotch + IslandExpandedLayout.cardHeight + IslandExpandedLayout.padding)
        for tab in [IslandTab.utilities, .developer] { #expect(layout(tab, panel: true).height == layout(tab, panel: false).height) }
    }

    // El alto con el panel cabe en el lienzo de la ventana (con su sombra) para cualquier alto de notch
    @MainActor
    @Test func thePanelFitsTheWindowCanvasForEveryNotchHeight() {
        for topHeight in stride(from: 22.0, through: 44.0, by: 2.0) {
            #expect(layout(.desktops, panel: true, topHeight: topHeight).height + 16 <= IslandController.canvasHeight, "notch de \(topHeight) pt")
        }
    }

    // La tarjeta «+» cierra la fila de tarjetas, sin ser una tarjeta de escritorio
    @Test func theAddCardClosesTheRowAndIsNotADesktopCard() throws {
        let design = layout(.desktops, panel: true, spaces: 5)
        let add = try #require(design.addCardFrame(islandWidth: 800, topHeight: 38))
        #expect(add.size == CGSize(width: 40, height: 70) && add.minY == 38 + IslandExpandedLayout.gapBelowNotch)
        // Pegada a la última tarjeta, con la fila centrada en la isla
        let cardsEnd = (800 - design.cardRowWidth) / 2 + design.cardsWidth
        #expect(add.minX == cardsEnd + IslandExpandedLayout.cardSpacing && abs(add.maxX - (800 + design.cardRowWidth) / 2) < 0.001)
        let point = CGPoint(x: add.midX, y: add.midY)
        #expect(design.cardIndex(at: point, islandWidth: 800, topHeight: 38) == nil)
        #expect(design.desktopControl(at: point, islandWidth: 800, topHeight: 38, windowIDs: []) == .newSpace)
        // Las tarjetas de verdad siguen respondiendo, también la última
        let last = CGPoint(x: cardsEnd - 10, y: add.midY)
        #expect(design.cardIndex(at: last, islandWidth: 800, topHeight: 38) == 4)
        #expect(design.cardIndex(at: CGPoint(x: (800 - design.cardRowWidth) / 2 + 10, y: add.midY), islandWidth: 800, topHeight: 38) == 0)
        // Sin el panel o en otra pestaña, no hay tarjeta «+»
        #expect(layout(.desktops, panel: false, spaces: 5).addCardFrame(islandWidth: 800, topHeight: 38) == nil)
        #expect(layout(.utilities, panel: true).addCardFrame(islandWidth: 800, topHeight: 38) == nil)
    }

    @Test func theIslandResolvesPanelClicksOnlyInTheDesktopsTab() throws {
        let desktops = layout(.desktops, panel: true)
        let frame = try #require(desktops.desktopPanelFrame(islandWidth: 800, topHeight: 38))
        // Debajo de las tarjetas y dentro de la isla
        #expect(frame.minY == 38 + IslandExpandedLayout.gapBelowNotch + IslandExpandedLayout.cardHeight + DesktopPanelLayout.gap)
        #expect(frame.height == DesktopPanelLayout.height && frame.minX >= 0 && frame.maxX <= 800)
        let panel = DesktopPanelLayout.frames(width: frame.width, windowCount: 0)
        let rotate = try #require(panel.buttons.first { $0.control == .rotate })
        let point = CGPoint(x: frame.minX + rotate.frame.midX, y: frame.minY + rotate.frame.midY)
        #expect(desktops.desktopControl(at: point, islandWidth: 800, topHeight: 38, windowIDs: []) == .rotate)
        #expect(desktops.desktopControl(at: CGPoint(x: 5, y: 5), islandWidth: 800, topHeight: 38, windowIDs: []) == nil)
        for other in [layout(.utilities, panel: true), layout(.developer, panel: true), layout(.desktops, panel: false)] {
            #expect(other.desktopPanelFrame(islandWidth: 800, topHeight: 38) == nil)
            #expect(other.desktopControl(at: point, islandWidth: 800, topHeight: 38, windowIDs: []) == nil)
        }
        // El panel no es una tarjeta
        #expect(desktops.cardIndex(at: point, islandWidth: 800, topHeight: 38) == nil)
    }
}

// MARK: - El cliente, con un yabai falso

struct YabaiClientActionTests {
    /// Un yabai falso que apunta lo que le piden y falla donde se le diga (un patrón de `case`)
    private func make(failing pattern: String? = nil, output: String = "") throws -> (path: String, log: URL) {
        let log = FileManager.default.temporaryDirectory.appending(path: "yabai-log-\(UUID().uuidString).txt")
        var body = "echo \"$@\" >> '\(log.path)'\n"
        if let pattern { body += "case \"$*\" in\n\(pattern)) echo 'no se pudo' >&2; exit 1;;\nesac\n" }
        if !output.isEmpty { body += "echo '\(output)'\n" }
        return (try FakeYabai.make(body), log)
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func eachCommandRunsInOrder() async throws {
        let fake = try make()
        try await YabaiClient(executablePath: fake.path).perform(.togglePresentation)
        #expect(calls(fake.log) == ["-m space --toggle padding", "-m space --toggle gap"])
        try await YabaiClient(executablePath: fake.path).perform(.moveWindow(id: 9, toSpace: 3))
        #expect(calls(fake.log).last == "-m window 9 --space 3")
    }

    @Test func aFailingCommandStopsTheRest() async throws {
        let fake = try make(failing: "*padding*")
        await #expect(throws: YabaiError.commandFailed(command: "yabai -m space --toggle padding", stderr: "no se pudo")) {
            try await YabaiClient(executablePath: fake.path).perform(.togglePresentation)
        }
        #expect(calls(fake.log) == ["-m space --toggle padding"])
    }

    // Quitar la regla que no estaba falla y no importa: sigue con añadirla y aplicarla
    @Test func anOptionalCommandThatFailsDoesNotStopTheAction() async throws {
        let fake = try make(failing: "*--remove*")
        try await YabaiClient(executablePath: fake.path).perform(.addFloatRule(app: "Notas"))
        let all = calls(fake.log)
        #expect(all.count == 3 && all[0].hasPrefix("-m rule --remove") && all[1].contains("manage=off") && all[2].hasPrefix("-m rule --apply"))
        // Pero si es la obligatoria la que falla, sí se corta
        let strict = try make(failing: "*--add*")
        await #expect(throws: YabaiError.self) { try await YabaiClient(executablePath: strict.path).perform(.addFloatRule(app: "Notas")) }
        #expect(calls(strict.log).count == 2)
    }

    // La pila no da la vuelta sola: del último pasa al primero
    @Test func theStackWrapsWhenYabaiSaysThereIsNoNext() async throws {
        let fake = try make(failing: "*stack.next*")
        try await YabaiClient(executablePath: fake.path).perform(.stackStep(forward: true))
        #expect(calls(fake.log) == ["-m window --focus stack.next", "-m window --focus stack.first"])
        // Si ni la alternativa vale, el error es el suyo
        let none = try make(failing: "*stack*")
        await #expect(throws: YabaiError.self) { try await YabaiClient(executablePath: none.path).perform(.stackStep(forward: false)) }
    }

    @Test func ifYabaiIsNotRunningNothingContinues() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "x-\(UUID().uuidString)")
        let body = "echo \"$@\" >> '\(log.path)'; echo 'yabai-msg: failed to connect to socket..' >&2; exit 1"
        let fake = try FakeYabai.make(body)
        // Ni siquiera la opcional sigue si yabai no responde: se corta en la primera
        await #expect(throws: YabaiError.notRunning) { try await YabaiClient(executablePath: fake).perform(.addFloatRule(app: "A")) }
        #expect(calls(log).count == 1)
    }

    // `--version` y `--restart-service` no llevan `-m`
    @Test func theDirectOptionsHaveNoMessageFlag() async throws {
        let fake = try make(output: "yabai-v7.1.25")
        let client = YabaiClient(executablePath: fake.path)
        #expect(try await client.version() == "yabai-v7.1.25")
        try await client.restartService()
        #expect(calls(fake.log) == ["--version", "--restart-service"])
    }

    @Test func ruleLabelsComeFromTheRuleList() async throws {
        let fake = try make(output: "[{\"index\":1,\"label\":\"yb_float_a\"},{\"index\":2},{\"index\":3,\"label\":\"otra\"}]")
        #expect(try await YabaiClient(executablePath: fake.path).ruleLabels() == ["yb_float_a", "otra"])
        #expect(calls(fake.log) == ["-m rule --list"])
    }
}

// MARK: - El almacén del panel, con falsos

private final class RecordingControl: YabaiControlling {
    private struct State { var actions: [YabaiAction] = []; var failure: YabaiError?; var running = 0; var maxRunning = 0; var delay = Duration.zero }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var actions: [YabaiAction] { state.withLock { $0.actions } }
    var maxConcurrent: Int { state.withLock { $0.maxRunning } }
    func fail(with error: YabaiError?) { state.withLock { $0.failure = error } }
    /// Lo que tarda cada acción: con retardo se ve si dos se cruzan
    func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

    func perform(_ action: YabaiAction) async throws {
        let (failure, delay) = state.withLock { state -> (YabaiError?, Duration) in
            state.actions.append(action)
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            return (state.failure, state.delay)
        }
        try? await Task.sleep(for: delay)
        state.withLock { $0.running -= 1 }
        if let failure { throw failure }
    }
}

@MainActor
struct DesktopControlStoreTests {
    private func make(
        scriptingAddition: Bool = true, confirm: Bool = true, windows: [YabaiWindow]? = nil
    ) -> (store: DesktopControlStore, control: RecordingControl, settings: AppSettings, changed: () -> Int) {
        let control = RecordingControl()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "yabai-panel-\(UUID().uuidString)")!)
        let query = StubYabai(
            [.init(spaces: [space(1), space(2, focus: true, type: "stack")])],
            windows: .success(windows ?? [window(20, space: 2, app: "Notas", title: "Ideas", focus: true), window(21, space: 2, app: "Mail", title: "Bandeja")])
        )
        let store = DesktopControlStore(query: query, control: control, settings: settings, scriptingAddition: { scriptingAddition }, confirm: { _, _, _ in confirm })
        let counter = OSAllocatedUnfairLock(initialState: 0)
        store.onChanged = { counter.withLock { $0 += 1 } }
        return (store, control, settings, { counter.withLock { $0 } })
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func itOnlyReadsWhileTheTabIsVisible() async throws {
        let (store, _, _, _) = make()
        #expect(!store.isRunning && store.snapshot.spaceIndex == nil)
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex != nil }
        #expect(store.isRunning && store.snapshot.spaceIndex == 2 && store.snapshot.layout == .stack)
        #expect(store.snapshot.windows.map(\.title) == ["Ideas", "Bandeja"] && store.snapshot.focused?.app == "Notas")
        store.setVisible(false)
        #expect(!store.isRunning && store.snapshot == DesktopControlSnapshot())
    }

    @Test func aPressedButtonIsPerformedAndSaid() async throws {
        let (store, control, _, changed) = make()
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex != nil }
        store.perform(.balance)
        try await wait { !control.actions.isEmpty && store.snapshot.message != nil }
        #expect(control.actions == [.balance] && store.snapshot.message == DesktopControlMessage(text: "Equilibrar las ventanas", isError: false))
        // Cambia lo que se ve: la isla vuelve a leer
        try await wait { changed() == 1 }
        #expect(changed() == 1)
    }

    @Test func withoutAFocusedWindowItSaysSo() async throws {
        let (store, control, _, _) = make(windows: [window(20, space: 2, focus: false)])
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex != nil }
        store.press(.toggleFloat)
        #expect(control.actions.isEmpty && store.snapshot.message == DesktopControlMessage(text: "No hay ninguna ventana enfocada", isError: true))
    }

    // Sin la scripting addition, lo que la necesita ni se intenta: se dice cómo cargarla
    @Test func whatNeedsTheScriptingAdditionIsNotTriedWithoutIt() async throws {
        let (store, control, _, _) = make(scriptingAddition: false)
        store.perform(.createSpace)
        store.perform(.focusSpace(3))
        #expect(control.actions.isEmpty)
        #expect(store.snapshot.message == DesktopControlMessage(text: DesktopControlText.needsScriptingAddition, isError: true))
        // Moverse de ventana no la pide el manual: se intenta
        store.perform(.moveWindow(id: 20, toSpace: 1))
        try await wait { !control.actions.isEmpty }
        #expect(control.actions == [.moveWindow(id: 20, toSpace: 1)])
        // Con ella, sí
        let (loaded, loadedControl, _, _) = make(scriptingAddition: true)
        loaded.perform(.createSpace)
        try await wait { !loadedControl.actions.isEmpty }
        #expect(loadedControl.actions == [.createSpace])
    }

    @Test func removingADesktopAsksFirst() async throws {
        let (refused, refusedControl, _, _) = make(confirm: false)
        refused.perform(.destroySpace(2))
        try await Task.sleep(for: .milliseconds(150))
        #expect(refusedControl.actions.isEmpty)
        let (accepted, acceptedControl, _, _) = make(confirm: true)
        accepted.perform(.destroySpace(2))
        try await wait { !acceptedControl.actions.isEmpty }
        #expect(acceptedControl.actions == [.destroySpace(2)])
    }

    @Test func aFailureIsShownAsAnError() async throws {
        let (store, control, _, changed) = make()
        control.fail(with: .commandFailed(command: "yabai", stderr: "could not locate the selected window"))
        store.perform(.balance)
        try await wait { store.snapshot.message != nil }
        #expect(store.snapshot.message == DesktopControlMessage(text: "could not locate the selected window", isError: true))
        // Aun fallando se vuelve a leer: lo que se ve pudo cambiar a medias
        try await wait { changed() == 1 }
    }

    // «Recordar en el N» es lo que apunta la distribución: elegir una por sí solo no recuerda nada, y con él encendido se actualiza
    @Test func theLayoutIsOnlyRememberedWhenTheUserSaysSo() async throws {
        let (store, control, settings, _) = make()
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex == 2 }
        store.press(.layout(.bsp))
        try await wait { control.actions.count == 1 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(settings.rememberedLayouts.isEmpty)
        // Encender «Recordar en el 2» guarda la distribución de ahora (la pila)
        store.press(.rememberLayout)
        #expect(settings.rememberedLayouts == ["2": "stack"] && store.snapshot.rememberedLayouts == [2: .stack])
        #expect(DesktopControl.rememberLayout.isOn(snapshot: store.snapshot))
        // Y mientras esté encendido, cambiar de distribución lo actualiza
        store.press(.layout(.float))
        try await wait { settings.rememberedLayouts == ["2": "float"] }
        #expect(settings.rememberedLayouts == ["2": "float"])
        // Apagarlo la olvida
        store.press(.rememberLayout)
        #expect(settings.rememberedLayouts.isEmpty && !DesktopControl.rememberLayout.isOn(snapshot: store.snapshot))
        // Sin distribución leída no hay nada que recordar
        let (idle, _, idleSettings, _) = make()
        idle.press(.rememberLayout)
        #expect(idleSettings.rememberedLayouts.isEmpty && idle.snapshot.message?.isError == true)
    }

    @Test func theFloatingAppsAreRememberedWithTheirButton() async throws {
        let (store, control, settings, changed) = make()
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex == 2 }
        store.press(.floatApp)
        try await wait { settings.floatApps == ["Notas"] }
        #expect(settings.floatApps == ["Notas"] && store.snapshot.floatApps == ["Notas"])
        // Añadir la regla la aplica a las ventanas que hay (cambia lo que se ve) y la isla relee; quitarla no
        try await wait { changed() == 1 }
        #expect(changed() == 1)
        try await wait { store.snapshot.floatApps == ["Notas"] }
        store.press(.floatApp)
        try await wait { settings.floatApps.isEmpty }
        #expect(settings.floatApps.isEmpty)
        try await wait { control.actions.count == 2 }
        #expect(changed() == 1)
    }

    @Test func aFailedActionIsNotRemembered() async throws {
        let (store, control, settings, _) = make()
        settings.rememberedLayouts = ["2": "stack"]
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex == 2 }
        control.fail(with: .commandFailed(command: "yabai", stderr: "no"))
        store.press(.layout(.float))
        try await wait { control.actions.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(settings.rememberedLayouts == ["2": "stack"])
    }

    // La presentación no se puede leer de yabai: la app apunta lo que ha hecho
    @Test func thePresentationSwitchFollowsWhatTheAppDid() async throws {
        let (store, control, _, _) = make()
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex == 2 }
        #expect(!DesktopControl.presentation.isOn(snapshot: store.snapshot))
        store.press(.presentation)
        try await wait { store.snapshot.presentationSpaces == [2] }
        #expect(DesktopControl.presentation.isOn(snapshot: store.snapshot))
        try await wait { control.actions.count == 1 }
        store.press(.presentation)
        try await wait { store.snapshot.presentationSpaces.isEmpty }
        #expect(!DesktopControl.presentation.isOn(snapshot: store.snapshot) && control.actions == [.togglePresentation, .togglePresentation])
    }

    // La versión de yabai, una vez por sesión, para la cabecera de la sección «yabai»
    @Test func theYabaiVersionIsReadOnceWhileVisible() async throws {
        let control = RecordingControl()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "yabai-panel-\(UUID().uuidString)")!)
        let query = StubYabai([.init(spaces: [space(1, focus: true)])], windows: .success([]))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = DesktopControlStore(query: query, control: control, settings: settings, scriptingAddition: { true }, version: {
            calls.withLock { $0 += 1 }
            return "yabai-v7.1.25"
        })
        store.setVisible(true)
        try await wait { store.snapshot.yabaiVersion != nil }
        #expect(store.snapshot.yabaiVersion == "yabai-v7.1.25")
        store.setVisible(false)
        store.setVisible(true)
        try await wait { store.snapshot.spaceIndex != nil }
        #expect(calls.withLock { $0 } == 1 && store.snapshot.yabaiVersion == "yabai-v7.1.25")
        store.setVisible(false)
    }

    // «Atajos de skhd» lo atiende la isla: el almacén no hace nada con él
    @Test func theSkhdButtonIsNotAYabaiCommand() {
        let (store, control, _, _) = make()
        store.press(.skhd)
        #expect(control.actions.isEmpty && store.snapshot.message == nil)
    }

    @Test func twoClicksInARowDoNotCross() async throws {
        let (store, control, _, _) = make()
        control.setDelay(.milliseconds(120))
        store.perform(.balance)
        store.perform(.rotate)
        try await wait { control.actions.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(control.actions == [.balance, .rotate] && control.maxConcurrent == 1)
    }

    // Quitar un escritorio: una sola pregunta aunque se pulse de nuevo, la isla se cierra antes, y se vuelve a mirar cuál es el activo
    @Test func removingADesktopAsksOnceAndChecksTheActiveOne() async throws {
        let control = RecordingControl()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "yabai-panel-\(UUID().uuidString)")!)
        let query = StubYabai([.init(spaces: [space(1), space(2, focus: true)])], windows: .success([]))
        var asked = 0
        var closed = 0
        var store: DesktopControlStore!
        store = DesktopControlStore(query: query, control: control, settings: settings, scriptingAddition: { true }, confirm: { _, _, _ in
            asked += 1
            // Con el aviso abierto, otro clic en «−» no abre una segunda pregunta
            store.perform(.destroySpace(2))
            return true
        })
        store.onWillAsk = { closed += 1 }
        store.perform(.destroySpace(2))
        try await wait { !control.actions.isEmpty }
        #expect(asked == 1 && closed == 1 && control.actions == [.destroySpace(2)])
        // El activo ya no es el que se preguntó: no se quita nada
        let moved = RecordingControl()
        let other = DesktopControlStore(
            query: StubYabai([.init(spaces: [space(1, focus: true), space(2)])], windows: .success([])), control: moved, settings: settings,
            scriptingAddition: { true }, confirm: { _, _, _ in true }
        )
        other.perform(.destroySpace(2))
        try await wait { other.snapshot.message != nil }
        #expect(moved.actions.isEmpty && other.snapshot.message?.isError == true)
    }

    // Lo recordado va con su escritorio cuando se quita o se mueve otro
    @Test func rememberedLayoutsShiftWhenDesktopsAreRemovedOrMoved() async throws {
        let (store, _, settings, _) = make()
        settings.rememberedLayouts = ["1": "bsp", "2": "stack", "3": "float"]
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex == 2 }
        // El escritorio activo del falso es el 2: quitar el 2 baja el 3
        store.perform(.destroySpace(2))
        try await wait { settings.rememberedLayouts == ["1": "bsp", "2": "float"] }
        #expect(settings.rememberedLayouts == ["1": "bsp", "2": "float"])
        store.perform(.moveSpace(forward: true))
        try await wait { settings.rememberedLayouts == ["1": "bsp", "3": "float"] }
        #expect(settings.rememberedLayouts == ["1": "bsp", "3": "float"])
    }

    // Una lectura lenta que llega tras una más nueva no la pisa
    @Test func aSlowReadDoesNotOverwriteANewerOne() async throws {
        let control = RecordingControl()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "yabai-panel-\(UUID().uuidString)")!)
        let query = StubYabai(
            [.init(spaces: [space(1, focus: true)], delay: .milliseconds(400)), .init(spaces: [space(2, focus: true)])],
            windows: .success([])
        )
        let store = DesktopControlStore(query: query, control: control, settings: settings, scriptingAddition: { true })
        store.setVisible(true)
        defer { store.setVisible(false) }
        // La primera lectura (la del sondeo) tarda; la acción lanza otra rápida
        try await Task.sleep(for: .milliseconds(50))
        store.perform(.balance)
        try await wait { store.snapshot.spaceIndex == 2 }
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.snapshot.spaceIndex == 2)
    }

    // Con la pestaña oculta una acción no consulta nada
    @Test func anActionWithTheTabHiddenReadsNothing() async throws {
        let control = RecordingControl()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "yabai-panel-\(UUID().uuidString)")!)
        let query = StubYabai([.init(spaces: [space(1, focus: true)])], windows: .success([]))
        let store = DesktopControlStore(query: query, control: control, settings: settings, scriptingAddition: { true })
        store.perform(.balance)
        try await wait { !control.actions.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        #expect(query.spacesCallCount == 0)
    }

    @Test func theMessageGoesAwayByItself() async throws {
        let (store, _, _, _) = make()
        store.perform(.balance)
        try await wait { store.snapshot.message != nil }
        #expect(store.snapshot.message != nil)
        try await wait { store.snapshot.message == nil }
        #expect(store.snapshot.message == nil)
    }

    #if DEBUG
    @Test func theImageSnapshotHidesRealTitlesButNotTheDemo() async throws {
        let (store, _, _, _) = make()
        store.setVisible(true)
        defer { store.setVisible(false) }
        try await wait { store.snapshot.spaceIndex == 2 }
        #expect(store.snapshotForImage.windows.allSatisfy { $0.title == "••••••••" } && store.snapshot.windows.first?.title == "Ideas")
        store.injectDemo()
        #expect(store.snapshotForImage.windows.first?.title == "Documentación de yabai")
        store.resetInjected()
        #expect(store.snapshot.windows.first?.title == "Ideas")
    }
    #endif
}

// MARK: - Los ajustes de lo recordado

@MainActor
struct YabaiSettingsTests {
    @Test func theNewSettingsHaveTheirDefaultsAndAreRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "yabai-settings-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.showDesktopPanel && !settings.instantSwitch && settings.rememberedLayouts.isEmpty && settings.floatApps.isEmpty)
        settings.showDesktopPanel = false
        settings.instantSwitch = true
        settings.rememberedLayouts = ["2": "stack"]
        settings.floatApps = ["Notas", "Calculadora"]
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.showDesktopPanel && reloaded.instantSwitch && reloaded.rememberedLayouts == ["2": "stack"])
        #expect(reloaded.floatApps == ["Notas", "Calculadora"])
    }

    // Lo guardado que no vale (editado a mano) no llega a yabai
    @Test func storedFloatAppsAreCleanedOnLoad() throws {
        let defaults = try #require(UserDefaults(suiteName: "yabai-settings-\(UUID().uuidString)"))
        defaults.set(["  Notas ", "", "dos\nlíneas", "Mail"], forKey: "floatApps")
        #expect(AppSettings(defaults: defaults).floatApps == ["Notas", "Mail"])
    }
}

// MARK: - Lo que la app vuelve a poner

struct YabaiRestoreRuleTests {
    // Solo tras un reinicio: yabai dejó de responder (el socket) y volvió. Un error cualquiera que se recupera no lo es
    @Test func itOnlyRestoresAfterARealRestart() {
        #expect(YabaiMaintenance.restoresAfterRecovery(wasFailing: true, failing: false, sawNotRunning: true))
        #expect(!YabaiMaintenance.restoresAfterRecovery(wasFailing: true, failing: false, sawNotRunning: false))
        #expect(!YabaiMaintenance.restoresAfterRecovery(wasFailing: true, failing: true, sawNotRunning: true))
        #expect(!YabaiMaintenance.restoresAfterRecovery(wasFailing: false, failing: false, sawNotRunning: true))
    }
}

@MainActor
struct YabaiMaintenanceTests {
    private func make(
        spaces: [YabaiSpace], rules: String = "[]", settings configure: (AppSettings) -> Void
    ) async throws -> (maintenance: YabaiMaintenance, log: URL, settings: AppSettings) {
        let log = FileManager.default.temporaryDirectory.appending(path: "yabai-maint-\(UUID().uuidString).txt")
        let body = "echo \"$@\" >> '\(log.path)'\nif [ \"$2\" = \"rule\" ] && [ \"$3\" = \"--list\" ]; then echo '\(rules)'; fi"
        let client = YabaiClient(executablePath: try FakeYabai.make(body))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "yabai-maint-\(UUID().uuidString)")!)
        configure(settings)
        let store = SpacesStore(yabai: StubYabai([.init(spaces: spaces)]), debounce: .milliseconds(1))
        await store.refresh()
        return (YabaiMaintenance(client: client, settings: settings, store: store, confirm: { _, _, _ in true }), log, settings)
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // yabai se reinició: el escritorio 2 volvió a mosaico, y la regla ya no está
    @Test func itPutsBackWhatYabaiLost() async throws {
        let (maintenance, log, _) = try await make(spaces: [space(1, focus: true, type: "bsp"), space(2, type: "bsp")]) {
            $0.rememberedLayouts = ["1": "bsp", "2": "stack"]
            $0.floatApps = ["Notas"]
        }
        await maintenance.restore()
        let all = calls(log)
        #expect(all.contains("-m space 2 --layout stack") && !all.contains { $0.contains("space 1 --layout") })
        let label = YabaiRules.label(for: "Notas")
        #expect(all.contains("-m rule --add label=\(label) app=\(YabaiRules.pattern(for: "Notas")) manage=off") && all.contains("-m rule --apply \(label)"))
    }

    @Test func itLeavesAloneWhatYabaiStillHas() async throws {
        let label = YabaiRules.label(for: "Notas")
        let (maintenance, log, _) = try await make(spaces: [space(1, focus: true, type: "stack")], rules: "[{\"label\":\"\(label)\"}]") {
            $0.rememberedLayouts = ["1": "stack"]
            $0.floatApps = ["Notas"]
        }
        await maintenance.restore()
        // Solo consultó las reglas: no cambió nada
        #expect(calls(log) == ["-m rule --list"])
    }

    @Test func withNothingRememberedItDoesNothing() async throws {
        let (maintenance, log, _) = try await make(spaces: [space(1, focus: true)]) { _ in }
        await maintenance.restore()
        #expect(calls(log).isEmpty)
    }

    @Test func forgettingAndRemovingUpdateTheSettings() async throws {
        let (maintenance, log, settings) = try await make(spaces: [space(1, focus: true)]) {
            $0.rememberedLayouts = ["1": "bsp", "2": "stack"]
            $0.floatApps = ["Notas", "Mail"]
        }
        maintenance.forgetLayout(of: 1)
        #expect(settings.rememberedLayouts == ["2": "stack"])
        maintenance.removeFloatApp("Notas")
        #expect(settings.floatApps == ["Mail"])
        let deadline = Date().addingTimeInterval(3)
        while !calls(log).contains(where: { $0.hasPrefix("-m rule --remove") }), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls(log).contains("-m rule --remove \(YabaiRules.label(for: "Notas"))"))
        maintenance.forgetAllLayouts()
        #expect(settings.rememberedLayouts.isEmpty)
    }

    // Dos restauraciones a la vez no se pisan: la segunda no hace nada mientras la primera sigue
    @Test func twoRestoresDoNotRunAtOnce() async throws {
        let (maintenance, log, _) = try await make(spaces: [space(1, focus: true, type: "bsp")]) {
            $0.rememberedLayouts = ["1": "stack"]
        }
        async let first: Void = maintenance.restore()
        async let second: Void = maintenance.restore()
        _ = await (first, second)
        #expect(calls(log).filter { $0 == "-m space 1 --layout stack" }.count == 1)
    }
}

// MARK: - La chuleta de skhd

struct SkhdCheatSheetTests {
    private let sample = """
    # Escritorios
    shift + alt - 1 : yabai -m space --focus 1
    shift + alt - 2 : yabai -m window --space 2; \\
        yabai -m space --focus 2

    ## ---- Ventanas ----
    alt - h : yabai -m window --focus west
    cmd + ctrl - return : open -na Ghostty
    f1 : echo ayuda
    # alt - x : yabai -m window --toggle float
    :: modo : echo no
    .load "otro"
    alt - 0 ; modo < alt - x : echo con modo
    """

    @Test func bindingsAreGroupedByTheirComments() {
        let groups = SkhdCheatSheet.parse(sample)
        #expect(groups.map(\.title) == ["Escritorios", "Ventanas"])
        #expect(groups[0].bindings.count == 2 && groups[1].bindings.count >= 3)
        #expect(groups[0].bindings[0] == SkhdBinding(keys: "⇧⌥ 1", command: "yabai -m space --focus 1"))
    }

    @Test func aContinuedLineIsOneBinding() {
        let groups = SkhdCheatSheet.parse(sample)
        #expect(groups[0].bindings[1].command == "yabai -m window --space 2; yabai -m space --focus 2")
    }

    @Test func modifiersBecomeSymbolsAndSingleKeysStay() {
        #expect(SkhdCheatSheet.symbols(for: "cmd + ctrl - return") == "⌘⌃ return")
        #expect(SkhdCheatSheet.symbols(for: "hyper - a") == "⌘⌃⌥⇧ a")
        #expect(SkhdCheatSheet.symbols(for: "f1") == "f1")
        #expect(SkhdCheatSheet.symbols(for: "alt - 0x32") == "⌥ 0x32")
    }

    @Test func modesDirectivesAndCommentedBindingsAreSkipped() {
        let all = SkhdCheatSheet.parse(sample).flatMap(\.bindings)
        #expect(!all.contains { $0.command.contains("toggle float") || $0.command == "echo no" })
        #expect(all.contains { $0.keys == "f1" })
        // Un atajo con modo muestra solo el atajo
        #expect(all.contains { $0.command == "echo con modo" && $0.keys == "⌥ x" })
    }

    @Test func bindingsBeforeAnyCommentGetADefaultTitle() {
        #expect(SkhdCheatSheet.parse("alt - a : echo a").map(\.title) == [SkhdCheatSheet.defaultTitle])
    }

    @Test func aLongCommandIsShortenedAndTheListIsBounded() {
        let long = SkhdCheatSheet.parse("alt - a : " + String(repeating: "x", count: 500)).first?.bindings.first
        #expect(long?.command.count == SkhdCheatSheet.maxCommandLength && long?.command.hasSuffix("…") == true)
        let many = (0..<1000).map { "alt - a : echo \($0)" }.joined(separator: "\n")
        #expect(SkhdCheatSheet.parse(many).flatMap(\.bindings).count == SkhdCheatSheet.maxBindings)
    }

    @Test func garbageGivesNothing() {
        #expect(SkhdCheatSheet.parse("").isEmpty && SkhdCheatSheet.parse("solo texto sin dos puntos\n\n   \n").isEmpty)
        #expect(SkhdCheatSheet.parse(" : sin atajo\nalt - a : ").isEmpty)
    }

    // Los dotfiles suelen ser enlaces: el tope de tamaño mide el archivo al que apuntan
    @Test func aSymlinkToAHugeFileIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "skhd-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = folder.appending(path: "real")
        try String(repeating: "a", count: SkhdCheatSheet.maxFileBytes + 1).write(to: real, atomically: true, encoding: .utf8)
        let link = folder.appending(path: "skhdrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(SkhdCheatSheet.read(at: link) == nil)
        // Y uno razonable a través de un enlace sí se lee
        let small = folder.appending(path: "small")
        try "alt - a : echo a".write(to: small, atomically: true, encoding: .utf8)
        let smallLink = folder.appending(path: "otro")
        try FileManager.default.createSymbolicLink(at: smallLink, withDestinationURL: small)
        #expect(SkhdCheatSheet.read(at: smallLink)?.first?.bindings.count == 1)
    }

    @Test func aMissingOrHugeFileIsNil() throws {
        #expect(SkhdCheatSheet.read(at: URL(fileURLWithPath: "/no/existe/skhdrc")) == nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "skhd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "skhdrc")
        try sample.write(to: file, atomically: true, encoding: .utf8)
        #expect(SkhdCheatSheet.read(at: file)?.isEmpty == false)
        try String(repeating: "a", count: SkhdCheatSheet.maxFileBytes + 1).write(to: file, atomically: true, encoding: .utf8)
        #expect(SkhdCheatSheet.read(at: file) == nil)
    }
}
