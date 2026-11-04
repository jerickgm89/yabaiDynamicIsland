import Carbon.HIToolbox
import Foundation
import Testing
@testable import YabaiBar

// Cada test usa su propio dominio de UserDefaults, para no tocar los ajustes reales de la app que hace de host
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "com.jerickdev.yabaibar.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@MainActor
struct AppSettingsTests {
    @Test func startsWithTheDefaults() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.switchSpeed == .normal)
            #expect(settings.toggleShortcut == .defaultToggle)
            #expect(settings.autoHide)
            #expect(settings.autoHideDelay == 3)
            #expect(settings.openOnHover)
            #expect(settings.showNowPlaying)
            #expect(settings.nowPlayingSource == .any)
            #expect(settings.showMusicBars)
            #expect(settings.announceTracks)
            #expect(settings.batteryAlerts)
            #expect(settings.keepAwakeButton)
            #expect(settings.showPomodoro)
            #expect(settings.pomodoroPreset == .classic)
            #expect(settings.pomodoroAutoStartBreaks)
            #expect(!settings.pomodoroAutoStartFocus)
            #expect(settings.pomodoroWarning == 30)
            #expect(settings.pomodoroDailyGoal == 8)
            #expect(settings.showPomodoroRing)
            #expect(settings.pomodoroSound)
            #expect(settings.pomodoroDuckMusic)
            #expect(settings.pomodoroDuckLevel == 35)
            #expect(settings.pomodoroShortcut == .defaultPomodoro)
            #expect(settings.pomodoroShortcut?.label == "⌥P")
        }
    }

    @Test func remembersEveryChange() throws {
        try withDefaults { defaults in
            let shortcut = try #require(HotKeyShortcut(keyCode: kVK_ANSI_Y, modifiers: cmdKey | shiftKey, character: "y"))
            let settings = AppSettings(defaults: defaults)
            settings.switchSpeed = .fast
            settings.toggleShortcut = shortcut
            settings.autoHide = false
            settings.autoHideDelay = 7
            settings.openOnHover = false
            settings.showNowPlaying = false
            settings.nowPlayingSource = .tidal
            settings.showMusicBars = false
            settings.announceTracks = false
            settings.batteryAlerts = false
            settings.keepAwakeButton = false
            settings.pomodoroPreset = .long
            settings.pomodoroWarning = 60

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.switchSpeed == .fast)
            #expect(reloaded.toggleShortcut?.label == "⇧⌘Y")
            #expect(!reloaded.autoHide)
            #expect(reloaded.autoHideDelay == 7)
            #expect(!reloaded.openOnHover)
            #expect(!reloaded.showNowPlaying)
            #expect(reloaded.nowPlayingSource == .tidal)
            #expect(!reloaded.showMusicBars)
            #expect(!reloaded.announceTracks)
            #expect(!reloaded.batteryAlerts)
            #expect(!reloaded.keepAwakeButton)
            #expect(reloaded.pomodoroPreset == .long)
            #expect(reloaded.pomodoroDurations.focus == 50 * 60)
            #expect(reloaded.pomodoroWarning == 60)
        }
    }

    // Quitar el atajo no es lo mismo que no haberlo tocado nunca: no vuelve a ⌥I ni a ⌥P
    @Test func remembersHavingNoShortcut() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.toggleShortcut = nil
            settings.pomodoroShortcut = nil
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.toggleShortcut == nil)
            #expect(reloaded.pomodoroShortcut == nil)
        }
    }

    // Cambiar un tiempo a mano deja el preset en "Personalizado"
    @Test func editingATimeMakesThePresetCustom() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.pomodoroFocusMinutes = 30
            #expect(settings.pomodoroPreset == .custom)
            settings.pomodoroPreset = .short
            #expect(settings.pomodoroFocusMinutes == 15)
        }
    }

    @Test func ignoresUnknownOrOutOfRangeValues() {
        withDefaults { defaults in
            defaults.set("warp", forKey: "switchSpeed")
            defaults.set(60, forKey: "autoHideDelay")
            defaults.set(Data("basura".utf8), forKey: "toggleShortcut")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.switchSpeed == .normal)
            #expect(settings.autoHideDelay == 3)
            #expect(settings.toggleShortcut == .defaultToggle)
        }
    }
}

struct NowPlayingSourceTests {
    @Test func onlyTidalFiltersOtherApps() {
        #expect(NowPlayingSource.any.accepts("com.google.Chrome"))
        #expect(NowPlayingSource.tidal.accepts(NowPlaying.tidalBundleID))
        #expect(!NowPlayingSource.tidal.accepts("com.google.Chrome"))
    }
}

struct SwitchSpeedTests {
    @Test func scalesTheNormalTimes() {
        let tuck = Duration.milliseconds(300)
        #expect(SwitchSpeed.normal.scaled(tuck) == tuck)
        let slow = SwitchSpeed.slow.scaled(tuck)
        #expect(slow > .milliseconds(499) && slow < .milliseconds(501))
        #expect(SwitchSpeed.fast.scaled(tuck) < tuck)
        #expect(SwitchSpeed.instant.scaled(tuck) == .zero)
        #expect(SwitchSpeed.instant.animation(.smooth) == nil)
    }
}

struct HotKeyShortcutTests {
    @Test func theDefaultIsOptionI() {
        #expect(HotKeyShortcut(keyCode: kVK_ANSI_I, modifiers: optionKey, character: "i") == .defaultToggle)
        #expect(HotKeyShortcut.defaultToggle.label == "⌥I")
    }

    @Test func writesTheModifiersInTheMacOSOrder() {
        let all = HotKeyShortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey | shiftKey | optionKey | controlKey, character: "k")
        #expect(all?.label == "⌃⌥⇧⌘K")
        #expect(HotKeyShortcut(keyCode: kVK_Space, modifiers: optionKey, character: " ")?.label == "⌥Espacio")
    }

    // Sin ⌘, ⌥ ni ⌃, una letra se dejaría de poder escribir en todas las apps
    @Test func lettersNeedARealModifier() {
        #expect(HotKeyShortcut(keyCode: kVK_ANSI_I, modifiers: 0, character: "i") == nil)
        #expect(HotKeyShortcut(keyCode: kVK_ANSI_I, modifiers: shiftKey, character: "i") == nil)
    }

    @Test func functionKeysWorkAlone() {
        #expect(HotKeyShortcut(keyCode: kVK_F5, modifiers: 0, character: "")?.label == "F5")
    }

    // Esc cierra la isla y cancela la grabación
    @Test func escapeIsReserved() {
        #expect(HotKeyShortcut(keyCode: kVK_Escape, modifiers: optionKey, character: "\u{1B}") == nil)
    }
}
