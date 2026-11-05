import Foundation
import Testing
@testable import YabaiBar

// La pantalla del MacBook Pro 16" del usuario, con la escala «Más espacio»
private let builtInScreen = SetupChecklist.Screen(
    name: "Pantalla Retina integrada", size: CGSize(width: 2056, height: 1329), scale: 2,
    notch: CGSize(width: 220, height: 38), menuBarHeight: 39
)

struct SetupChecklistTests {
    private let ready = SetupChecklist.Inputs(
        model: "MacBookPro18,1", screens: [builtInScreen], yabaiInstalled: true, yabaiError: nil, signalsEnabled: true,
        desktops: [1, 2, 3, 4], desktopsWithShortcut: [1, 2, 3, 4], accessibility: true,
        launchAtLoginAvailable: true, launchAtLogin: true
    )

    private func row(_ item: SetupChecklist.Item, _ inputs: SetupChecklist.Inputs) -> SetupChecklist.Row? {
        SetupChecklist.rows(for: inputs).first { $0.item == item }
    }

    @Test func everythingReadyIsAllOK() {
        let rows = SetupChecklist.rows(for: ready)
        #expect(rows.count == 7)
        #expect(rows.allSatisfy { $0.status == .ok })
    }

    // Con notch vale cualquier Mac: el nombre sale del catálogo y las medidas, de la pantalla
    @Test func knownMacWithNotchShowsItsNameAndTheMeasuredNotch() {
        var inputs = ready
        inputs.model = "Mac16,1"
        inputs.screens[0].notch = CGSize(width: 184.6, height: 32)
        let model = row(.model, inputs)
        #expect(model?.status == .ok)
        #expect(model?.detail.hasPrefix("MacBook Pro de 14\" con M4 (2024). ") == true)
        #expect(model?.detail.contains("185 × 32 pt") == true)
        #expect(model?.action == .copyScreenReport)
    }

    // Un modelo que aún no está en el catálogo también vale, porque el notch se mide
    @Test func unknownMacWithNotchIsFineButUntested() {
        var inputs = ready
        inputs.model = "Mac18,3"
        let model = row(.model, inputs)
        #expect(model?.status == .ok)
        #expect(model?.detail.hasPrefix("Modelo Mac18,3, aún sin probar.") == true)
    }

    // Sin notch (un Mac de escritorio, un portátil sin notch o la tapa cerrada) se avisa, pero no se bloquea nada
    @Test func screensWithoutNotchWarn() {
        var inputs = ready
        inputs.screens = [SetupChecklist.Screen(
            name: "DELL U2723QE", size: CGSize(width: 2560, height: 1440), scale: 2, notch: nil, menuBarHeight: 24
        )]
        let closedLid = row(.model, inputs)
        #expect(closedLid?.status == .warning)
        #expect(closedLid?.detail.hasPrefix("MacBook Pro de 16\" con M1 Pro (2021) con la tapa cerrada: sin notch") == true)

        inputs.model = "Mac14,7"
        #expect(row(.model, inputs)?.detail.hasPrefix("MacBook Pro de 13\" con M2 (2022): sin notch") == true)
        inputs.model = "Mac14,13"
        #expect(row(.model, inputs)?.detail.hasPrefix("Modelo Mac14,13: sin notch") == true)
        #expect(row(.model, inputs)?.action == .copyScreenReport)
    }

    @Test func screenReportListsTheMacAndEveryScreen() {
        let monitor = SetupChecklist.Screen(
            name: "DELL U2723QE", size: CGSize(width: 1920, height: 1080), scale: 1, notch: nil, menuBarHeight: 0
        )
        var notched = builtInScreen
        notched.notch = CGSize(width: 184.5, height: 32)
        let report = SetupChecklist.screenReport(
            model: "MacBookPro18,1", appVersion: "3.1.0", system: "macOS Versión 27.2", screens: [notched, monitor]
        )
        #expect(report == """
            YabaiBar 3.1.0 · macOS Versión 27.2
            Mac: MacBookPro18,1 (MacBook Pro de 16" con M1 Pro (2021))
            Pantalla 1: Pantalla Retina integrada · 2056 × 1329 pt · ×2 · notch 184.5 × 32 pt · barra 39 pt
            Pantalla 2: DELL U2723QE · 1920 × 1080 pt · ×1 · sin notch · barra 0 pt
            """)
    }

    @Test func missingYabaiOffersHomebrewAndBlocksRunning() {
        var inputs = ready
        inputs.yabaiInstalled = false
        inputs.yabaiError = .notInstalled(path: "/opt/homebrew/bin/yabai")
        #expect(row(.yabaiInstalled, inputs)?.status == .missing)
        #expect(row(.yabaiInstalled, inputs)?.action == .installYabai)
        #expect(row(.yabaiRunning, inputs)?.status == .missing)
        #expect(row(.yabaiRunning, inputs)?.action == nil)
    }

    @Test func stoppedYabaiOffersStartService() {
        var inputs = ready
        inputs.yabaiError = .notRunning
        #expect(row(.yabaiRunning, inputs)?.status == .missing)
        #expect(row(.yabaiRunning, inputs)?.action == .startYabai)
    }

    // Instalado después de abrir YabaiBar: arrancar yabai no lo arregla
    @Test func yabaiInstalledAfterLaunchAsksForARestart() {
        var inputs = ready
        inputs.yabaiError = .notInstalled(path: "/opt/homebrew/bin/yabai")
        #expect(row(.yabaiRunning, inputs)?.status == .warning)
        #expect(row(.yabaiRunning, inputs)?.action == nil)
    }

    @Test func otherYabaiErrorsWarnWithTheirMessage() {
        var inputs = ready
        inputs.yabaiError = .timedOut(command: "yabai -m query --spaces")
        #expect(row(.yabaiRunning, inputs)?.status == .warning)
        #expect(row(.yabaiRunning, inputs)?.detail == "yabai no respondió a tiempo")
    }

    @Test func signalsOffWarnsAndKeepsTheToggle() {
        var inputs = ready
        inputs.signalsEnabled = false
        #expect(row(.signals, inputs)?.status == .warning)
        #expect(row(.signals, inputs)?.action == .signalsToggle)
    }

    @Test func desktopShortcutsListTheMissingOnes() {
        var inputs = ready
        inputs.desktops = [1, 2, 3, 4, 5, 6]
        let partial = row(.desktopShortcuts, inputs)
        #expect(partial?.status == .warning)
        #expect(partial?.detail.hasPrefix("Sin atajo: los escritorios 5 y 6.") == true)
        #expect(partial?.action == .addDesktopShortcuts)

        inputs.desktopsWithShortcut = []
        #expect(row(.desktopShortcuts, inputs)?.status == .missing)
    }

    // Mission Control solo tiene atajos hasta el escritorio 9
    @Test func desktopsBeyondNineDoNotCount() {
        var inputs = ready
        inputs.desktops = [1, 2, 3, 4, 10, 11]
        #expect(row(.desktopShortcuts, inputs)?.status == .ok)
    }

    @Test func accessibilityAndLaunchAtLogin() {
        var inputs = ready
        inputs.accessibility = false
        inputs.launchAtLogin = false
        #expect(row(.accessibility, inputs)?.action == .requestAccessibility)
        #expect(row(.launchAtLogin, inputs)?.status == .warning)
        #expect(row(.launchAtLogin, inputs)?.action == .launchAtLoginToggle)

        // Fuera de /Applications no se ofrece el interruptor
        inputs.launchAtLoginAvailable = false
        #expect(row(.launchAtLogin, inputs)?.action == nil)
    }
}
