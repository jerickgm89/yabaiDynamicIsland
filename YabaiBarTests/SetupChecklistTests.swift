import Testing
@testable import YabaiBar

struct SetupChecklistTests {
    private let ready = SetupChecklist.Inputs(
        model: "MacBookPro18,1", yabaiInstalled: true, yabaiError: nil, signalsEnabled: true,
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

    @Test func onlyM1ProAndMaxWithNotchAreSupported() {
        for model in ["MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4"] {
            #expect(SetupChecklist.isSupported(model: model))
        }
        // M1 de 13" sin notch, M2 Air y M2 Pro de 14" y un Mac de sobremesa
        for model in ["MacBookPro17,1", "Mac14,2", "Mac14,6", "Mac13,1", ""] {
            #expect(!SetupChecklist.isSupported(model: model))
        }
    }

    // Un Mac no soportado avisa, pero no bloquea nada
    @Test func unsupportedModelWarns() {
        var inputs = ready
        inputs.model = "Mac14,6"
        let model = row(.model, inputs)
        #expect(model?.status == .warning)
        #expect(model?.detail.contains("Mac14,6") == true)
        #expect(model?.detail.contains("próximas versiones") == true)
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
        #expect(partial?.detail.hasPrefix("Sin atajo: los escritorios 5, 6.") == true)
        #expect(partial?.action == .keyboardSettings)

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
