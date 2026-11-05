import AppKit
import ApplicationServices
import SwiftUI
import os

// "Primeros pasos": se abre sola la primera vez y después desde el menú. Como la de ajustes, activa la app al
// abrirse y la desactiva al cerrarse. Mientras está abierta, la lista se pone al día cada segundo y medio, porque
// los permisos y los atajos de Mission Control no avisan cuando cambian.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let status: SetupStatus
    private var window: NSWindow?

    init(settings: AppSettings, store: SpacesStore, focuser: ShortcutFocuser, launchAtLogin: LaunchAtLogin) {
        self.settings = settings
        status = SetupStatus(settings: settings, store: store, focuser: focuser, launchAtLogin: launchAtLogin)
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        status.start()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Lo que mide la ventana si cabe; con escalas de texto grande se acorta a la pantalla y la lista hace scroll
    private static let preferredHeight: CGFloat = 820
    private static let titleBarHeight: CGFloat = 28

    private func makeWindow() -> NSWindow {
        let available = (NSScreen.main?.visibleFrame.height).map { $0 - Self.titleBarHeight } ?? Self.preferredHeight
        let height = min(Self.preferredHeight, available)
        let view = WelcomeView(settings: settings, status: status, height: height) { [weak self] in self?.window?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Primeros pasos"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        status.stop()
        NSApp.deactivate()
    }

    #if DEBUG
    /// yabaibar://snapshot?bienvenida: la ventana tal cual se ve, en ~/Library/Caches/com.jerickdev.yabaibar/welcome.png
    func saveSnapshot() {
        show()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL.cachesDirectory.appending(path: "com.jerickdev.yabaibar/welcome.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            Logger.app.info("Snapshot de la bienvenida: \(url.path(percentEncoded: false), privacy: .public)")
        }
    }
    #endif
}

// Reúne lo que necesita SetupChecklist y hace lo que piden los botones de cada fila
@MainActor
@Observable
final class SetupStatus {
    private(set) var rows: [SetupChecklist.Row] = []
    /// Lo que copia «Copiar datos» en la fila del Mac
    private(set) var screenReport = ""

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: SpacesStore
    @ObservationIgnored private let focuser: ShortcutFocuser
    @ObservationIgnored private let launchAtLogin: LaunchAtLogin
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    init(settings: AppSettings, store: SpacesStore, focuser: ShortcutFocuser, launchAtLogin: LaunchAtLogin) {
        self.settings = settings
        self.store = store
        self.focuser = focuser
        self.launchAtLogin = launchAtLogin
        update()
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: .milliseconds(1500), tolerance: .milliseconds(300))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func update() {
        // Si acabas de arrancar yabai, el error se queda hasta el siguiente refresco
        if store.lastError != nil { store.requestRefresh() }
        let desktops = store.spaces.map(\.index)
        let screens = NSScreen.screens.map(Self.describe)
        let inputs = SetupChecklist.Inputs(
            model: MacModels.current,
            screens: screens,
            yabaiInstalled: FileManager.default.isExecutableFile(atPath: YabaiClient.resolvedPath()),
            yabaiError: store.lastError,
            signalsEnabled: settings.autoYabaiSignals,
            desktops: desktops,
            desktopsWithShortcut: Set(focuser.labels(for: desktops.isEmpty ? [1, 2] : desktops).keys),
            accessibility: AXIsProcessTrusted(),
            launchAtLoginAvailable: launchAtLogin.isAvailable,
            launchAtLogin: launchAtLogin.isEnabled
        )
        let newRows = SetupChecklist.rows(for: inputs)
        if newRows != rows { rows = newRows }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let report = SetupChecklist.screenReport(
            model: MacModels.current, appVersion: version,
            system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", screens: screens
        )
        if report != screenReport { screenReport = report }
    }

    private static func describe(_ screen: NSScreen) -> SetupChecklist.Screen {
        let geometry = screen.notchGeometry
        return SetupChecklist.Screen(
            name: screen.localizedName, size: screen.frame.size, scale: screen.backingScaleFactor,
            notch: geometry.hasNotch ? geometry.notch.size : nil, menuBarHeight: screen.menuBarHeight
        )
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openYabaiWiki() { NSWorkspace.shared.open(SetupChecklist.yabaiWiki) }
    func openKeyboardSettings() { NSWorkspace.shared.open(Self.keyboardSettings) }

    func requestAccessibility() {
        focuser.requestPermission()
        update()
    }

    func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        update()
    }
}

private struct WelcomeView: View {
    @Bindable var settings: AppSettings
    let status: SetupStatus
    let height: CGFloat
    let close: () -> Void
    @State private var copied: SetupChecklist.Item?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(status.rows, id: \.item) { row in
                        HStack(alignment: .top, spacing: 10) {
                            icon(for: row.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                Text(row.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            action(for: row)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bienvenido a YabaiBar").font(.title2.bold()).foregroundStyle(.primary)
                        Text("La isla muestra tus escritorios de yabai alrededor del notch. Esto es lo que necesita; la lista se actualiza sola.")
                            .font(.body)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                }

                Section("Para abrir la isla") {
                    LabeledContent("Pasa el puntero por el notch", value: settings.openOnHover ? "Activado" : "Desactivado")
                    LabeledContent("Atajo", value: settings.toggleShortcut?.label ?? "Sin atajo")
                    LabeledContent("Trackpad", value: "3 o 4 dedos hacia abajo")
                    if settings.showPomodoro {
                        LabeledContent("Pomodoro", value: settings.pomodoroShortcut?.label ?? "Sin atajo")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Vuelve a abrirla desde el menú de la isla › Primeros pasos…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Empezar", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: height)
    }

    private func icon(for status: SetupChecklist.Status) -> some View {
        let (name, color): (String, Color) = switch status {
        case .ok: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .missing: ("xmark.circle.fill", .red)
        }
        return Image(systemName: name).foregroundStyle(color).font(.title3).frame(width: 22)
    }

    @ViewBuilder
    private func action(for row: SetupChecklist.Row) -> some View {
        switch row.action {
        case .copyScreenReport?:
            copyButton(status.screenReport, for: row.item, title: "Copiar datos")
        case .installYabai?:
            HStack {
                copyButton(SetupChecklist.installYabai, for: row.item)
                Button("Wiki", action: status.openYabaiWiki)
            }
        case .startYabai?:
            copyButton(SetupChecklist.startYabai, for: row.item)
        case .signalsToggle?:
            Toggle("", isOn: $settings.autoYabaiSignals).labelsHidden().toggleStyle(.switch)
        case .keyboardSettings?:
            Button("Abrir Teclado", action: status.openKeyboardSettings)
        case .requestAccessibility?:
            Button("Dar permiso", action: status.requestAccessibility)
        case .launchAtLoginToggle?:
            Toggle("", isOn: Binding(get: { row.status == .ok }, set: { _ in status.toggleLaunchAtLogin() }))
                .labelsHidden()
                .toggleStyle(.switch)
        case nil:
            EmptyView()
        }
    }

    private func copyButton(_ text: String, for item: SetupChecklist.Item, title: String = "Copiar") -> some View {
        Button(copied == item ? "Copiado" : title) {
            status.copy(text)
            copied = item
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copied == item { copied = nil }
            }
        }
        .help(text)
    }
}
