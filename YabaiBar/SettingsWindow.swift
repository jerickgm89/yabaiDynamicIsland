import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

// La ventana de ajustes, con pestañas de ícono en la barra de la ventana, como las preferencias de macOS. Se abre
// desde el engranaje de la isla abierta y desde el menú. La app no sale en el Dock: al abrirla se activa, para que la
// ventana quede delante y reciba el teclado (el grabador de atajos lo necesita), y al cerrarla se desactiva.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case general, island, music, pomodoro, desktops, shortcuts, about

        var title: String {
            switch self {
            case .general: "General"
            case .island: "Isla"
            case .music: "Música"
            case .pomodoro: "Pomodoro"
            case .desktops: "Escritorios"
            case .shortcuts: "Atajos"
            case .about: "Acerca de"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .island: "capsule"
            case .music: "music.note"
            case .pomodoro: "timer"
            case .desktops: "square.grid.2x2"
            case .shortcuts: "keyboard"
            case .about: "info.circle"
            }
        }

        /// Cada pestaña mide lo que su contenido: la ventana cambia de alto al pasar de una a otra
        var height: CGFloat {
            switch self {
            case .general: 470
            case .island: 540
            case .music: 260
            case .pomodoro: 720
            case .desktops: 400
            case .shortcuts: 420
            case .about: 470
            }
        }
    }

    static let width: CGFloat = 560
    /// Lo que ocupa la barra con las pestañas, encima del contenido
    static let toolbarHeight: CGFloat = 90

    private let settings: AppSettings
    private let launchAtLogin: LaunchAtLogin
    private let showWelcome: @MainActor () -> Void
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    /// Al pasar a «Primeros pasos» la app sigue activa: esa ventana necesita el teclado
    private var handingOff = false

    init(settings: AppSettings, launchAtLogin: LaunchAtLogin, showWelcome: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.showWelcome = showWelcome
    }

    func show(tab: Tab? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        // Ninguna pestaña más alta que la pantalla (MacBook Air o escalas de texto grande): el Form hace scroll
        let available = (NSScreen.main?.visibleFrame.height).map { $0 - Self.toolbarHeight } ?? 720
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in Tab.allCases {
            let content = SettingsTabView(
                tab: tab, settings: settings, launchAtLogin: launchAtLogin,
                showWelcome: { [weak self] in
                    self?.handingOff = true
                    self?.window?.close()
                    self?.showWelcome()
                }
            )
            let height = min(tab.height, available)
            let controller = NSHostingController(rootView: content.frame(width: Self.width, height: height))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // Vuelve al frente la app que se estaba usando. Una grabación a medias se cancela, para que el atajo vuelva a funcionar
    func windowWillClose(_ notification: Notification) {
        settings.isRecordingShortcut = false
        if !handingOff { NSApp.deactivate() }
        handingOff = false
    }

    // Al pasar a una pestaña más alta, la ventana crece hacia abajo y AppKit no la recoloca: se sube si se sale
    func windowDidResize(_ notification: Notification) {
        guard let window, let visible = window.screen?.visibleFrame, window.frame.minY < visible.minY else { return }
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: min(visible.minY, visible.maxY - window.frame.height)))
    }

    #if DEBUG
    /// yabaibar://snapshot?ajustes=<pestaña>: la ventana con su barra, en ~/Library/Caches/com.jerickdev.yabaibar/ajustes.png
    func saveSnapshot(tab: Tab) {
        show(tab: tab)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard let frame = window?.contentView?.superview,
                  let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let url = URL.cachesDirectory.appending(path: "com.jerickdev.yabaibar/ajustes.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            let size = window?.frame.size ?? .zero
            Logger.app.info("Snapshot de los ajustes (\(tab.title, privacy: .public)): \(Int(size.width))×\(Int(size.height))")
        }
    }
    #endif
}

// Graba un atajo nuevo: al pulsarlo escucha la siguiente tecla. Esc cancela y ⌫ deja el atajo vacío. Mientras uno
// graba, no hay ningún atajo global registrado (`isRecordingShortcut`): Carbon se quedaría la tecla
struct ShortcutRecorder: View {
    @Binding var shortcut: HotKeyShortcut?
    let defaultShortcut: HotKeyShortcut
    /// Por qué no se pudo registrar, si pasó
    let error: String?
    @Bindable var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                if !recording, shortcut != defaultShortcut {
                    Button("Restablecer") { shortcut = defaultShortcut }
                }
                Button(action: toggleRecording) {
                    Text(title).frame(minWidth: 120)
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(rejected || (error != nil && !recording) ? .red : .secondary)
            }
        }
        .onDisappear(perform: stopRecording)
        // Si otro grabador termina, o se cierra la ventana, este deja de grabar y quita su monitor
        .onChange(of: settings.isRecordingShortcut) { _, recordingNow in
            if !recordingNow { stopRecording() }
        }
    }

    private var title: String {
        if recording { return "Pulsa el atajo…" }
        return shortcut?.label ?? "Sin atajo"
    }

    private var hint: String? {
        if rejected { return "Usa ⌘, ⌥ o ⌃ con otra tecla" }
        if recording { return "Esc cancela · ⌫ quita el atajo" }
        return error
    }

    private func toggleRecording() {
        if recording { return stopRecording() }
        rejected = false
        recording = true
        settings.isRecordingShortcut = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let modifiers = Self.carbonModifiers(event.modifierFlags)
            let character = event.charactersIgnoringModifiers ?? ""
            // Si la grabación terminó al cerrar la ventana, el monitor deja pasar la tecla
            let recorded = MainActor.assumeIsolated { () -> Bool in
                guard recording, settings.isRecordingShortcut else { return false }
                record(keyCode: keyCode, modifiers: modifiers, character: character)
                return true
            }
            // La tecla grabada no llega a la ventana
            return recorded ? nil : event
        }
    }

    private func record(keyCode: Int, modifiers: Int, character: String) {
        if modifiers == 0, keyCode == kVK_Escape { return stopRecording() }
        if modifiers == 0, keyCode == kVK_Delete {
            shortcut = nil
            return stopRecording()
        }
        guard let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: modifiers, character: character) else {
            rejected = true
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        rejected = false
        guard recording else { return }
        recording = false
        settings.isRecordingShortcut = false
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        return modifiers
    }
}
