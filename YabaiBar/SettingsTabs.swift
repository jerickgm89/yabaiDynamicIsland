import AppKit
import SwiftUI

// El contenido de cada pestaña de los ajustes (SettingsWindow). Solo reordena los ajustes de AppSettings: la pestaña
// «Isla» reúne lo que se ve en la isla, con una vista previa que cambia al momento.
struct SettingsTabView: View {
    let tab: SettingsWindow.Tab
    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let showWelcome: () -> Void

    var body: some View {
        switch tab {
        case .general: GeneralSettings(settings: settings, launchAtLogin: launchAtLogin, showWelcome: showWelcome)
        case .island: IslandSettings(settings: settings)
        case .music: MusicSettings(settings: settings)
        case .pomodoro: PomodoroSettings(settings: settings)
        case .desktops: DesktopSettings(settings: settings)
        case .shortcuts: ShortcutSettings(settings: settings)
        case .about: AboutSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let showWelcome: () -> Void
    /// LaunchAtLogin no avisa de los cambios: se lee al aparecer y tras cada cambio
    @State private var launches = false

    var body: some View {
        Form {
            Section {
                Toggle("Iniciar al arrancar", isOn: Binding(
                    get: { launches },
                    set: { wanted in
                        // Puede haber cambiado desde el menú: solo se toca si no está ya como lo pide el usuario
                        if wanted != launchAtLogin.isEnabled { launchAtLogin.toggle() }
                        launches = launchAtLogin.isEnabled
                    }
                ))
                .disabled(!launchAtLogin.isAvailable)
            } footer: {
                if !launchAtLogin.isAvailable {
                    Text("Solo desde /Applications: mueve allí YabaiBar.").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Al pasar el puntero", isOn: $settings.openOnHover)
                Toggle("Ocultar sola", isOn: $settings.autoHide)
                Stepper(value: $settings.autoHideDelay, in: AppSettings.autoHideDelays) {
                    Text("Al cabo de \(settings.autoHideDelay) s")
                }
                .disabled(!settings.autoHide)
            } header: {
                Text("Abrir la isla")
            } footer: {
                Text("También se abre con su atajo y con 3 o 4 dedos hacia abajo (pestaña Atajos). Abierta así, se oculta sola si no llevas el puntero hasta ella.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Velocidad de las alas", selection: $settings.switchSpeed) {
                    ForEach(SwitchSpeed.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Al cambiar de escritorio")
            } footer: {
                Text("Lo que tardan las alas en recogerse hacia el notch y volver a salir. El deslizamiento del escritorio es de macOS y no cambia.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Abrir «Primeros pasos»…", action: showWelcome)
            } footer: {
                Text("Comprueba yabai, los atajos de los escritorios y los permisos, y dice cómo arreglar lo que falte.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launches = launchAtLogin.isEnabled }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launches = launchAtLogin.isEnabled
        }
    }
}

// MARK: - Isla

private struct IslandSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                IslandPreview(
                    music: settings.showNowPlaying, pomodoro: settings.showPomodoro, cup: settings.keepAwakeButton
                )
                .frame(height: 150)
                HStack(spacing: 10) {
                    PartCard(title: "Música", symbol: "music.note", color: .accentColor, isOn: $settings.showNowPlaying)
                    PartCard(title: "Pomodoro", symbol: "timer", color: .red, isOn: $settings.showPomodoro)
                    PartCard(title: "Taza", symbol: "cup.and.saucer.fill", color: .orange, isOn: $settings.keepAwakeButton)
                }
            } header: {
                Text("En la isla abierta")
            } footer: {
                Text("Música: lo que suena. Pomodoro: foco y descansos (apagarlo termina la sesión). Taza: el Mac no se duerme mientras la tengas encendida.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Barras mientras suena música", isOn: $settings.showMusicBars)
                    .disabled(!settings.showNowPlaying)
                Toggle("Anillo del Pomodoro", isOn: $settings.showPomodoroRing)
                    .disabled(!settings.showPomodoro)
                Toggle("Aviso al cambiar de canción", isOn: $settings.announceTracks)
                    .disabled(!settings.showNowPlaying)
                Toggle("Avisos de la batería y el cargador", isOn: $settings.batteryAlerts)
            } header: {
                Text("En la isla cerrada")
            }
        }
        .formStyle(.grouped)
    }
}

// Una parte de la isla que se enciende o se apaga; la tarjeta entera hace de interruptor
private struct PartCard: View {
    let title: String
    let symbol: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? color : .secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

// Una isla abierta en miniatura con lo que está activado: los botones de arriba, las tarjetas y la fila de la música
// y el Pomodoro. No es la isla real: solo enseña qué partes se ven
private struct IslandPreview: View {
    let music: Bool
    let pomodoro: Bool
    let cup: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.16, green: 0.43, blue: 0.42))
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if pomodoro { Image(systemName: "timer").foregroundStyle(IslandView.focusColor) }
                    if cup { Image(systemName: "cup.and.saucer.fill").foregroundStyle(.white.opacity(0.6)) }
                    Spacer()
                    Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 16)
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(index == 1 ? Color.green.opacity(0.8) : .clear, lineWidth: 1.5)
                            )
                    }
                }
                .frame(height: 30)
                if music || pomodoro {
                    HStack(spacing: 12) {
                        if music {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(red: 0.24, green: 0.2, blue: 0.54))
                                    .frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Canción").font(.system(size: 11, weight: .semibold))
                                    Text("Artista").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                        }
                        if music && pomodoro {
                            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 34)
                        }
                        if pomodoro {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle().stroke(.white.opacity(0.14), lineWidth: 4)
                                    Circle().trim(from: 0, to: 0.7)
                                        .stroke(IslandView.focusColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                }
                                .frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Foco").font(.system(size: 11, weight: .semibold)).foregroundStyle(IslandView.focusColor)
                                    Text("18:42").font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: music ? 150 : .infinity)
                            .transition(.opacity)
                        }
                    }
                    .frame(height: 46)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(IslandShape(topRadius: 8, bottomRadius: 20).fill(.black))
            .padding(.horizontal, 14)
        }
        .animation(.smooth(duration: 0.25), value: [music, pomodoro, cup])
    }
}

// MARK: - Música

private struct MusicSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar lo que suena", isOn: $settings.showNowPlaying)
                Picker("De", selection: $settings.nowPlayingSource) {
                    ForEach(NowPlayingSource.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.showNowPlaying)
            } footer: {
                Text("Con la isla abierta, la carátula, la canción y sus botones; dos dedos de lado sobre ella cambian de canción. Lo lee del «Ahora suena» de macOS: no se envía nada a internet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pomodoro

private struct PomodoroSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            if !settings.showPomodoro {
                Section {
                    Text("El Pomodoro está apagado. Actívalo en la pestaña Isla.").foregroundStyle(.secondary)
                }
            }
            Section {
                HStack(spacing: 8) {
                    ForEach([PomodoroPreset.classic, .long, .short], id: \.self) { preset in
                        PresetCard(preset: preset, isSelected: settings.pomodoroPreset == preset) {
                            settings.pomodoroPreset = preset
                        }
                    }
                    // Con tiempos a mano: no se elige, solo dice que ninguno de los tres coincide
                    if settings.pomodoroPreset == .custom {
                        PresetCard(preset: .custom, isSelected: true) {}
                    }
                }
                Stepper(value: $settings.pomodoroFocusMinutes, in: AppSettings.focusMinutes, step: 5) {
                    Text("Foco: \(settings.pomodoroFocusMinutes) min")
                }
                Stepper(value: $settings.pomodoroShortBreakMinutes, in: AppSettings.shortBreakMinutes) {
                    Text("Descanso corto: \(settings.pomodoroShortBreakMinutes) min")
                }
                Stepper(value: $settings.pomodoroLongBreakMinutes, in: AppSettings.longBreakMinutes, step: 5) {
                    Text("Descanso largo: \(settings.pomodoroLongBreakMinutes) min")
                }
                Stepper(value: $settings.pomodoroRounds, in: AppSettings.pomodoroRoundsRange) {
                    Text("Descanso largo cada \(settings.pomodoroRounds) focos")
                }
            } header: {
                Text("Tiempos")
            } footer: {
                Text("Los cambios valen desde la siguiente fase. Si cambias un tiempo a mano, el preset pasa a «Personalizado».")
                    .foregroundStyle(.secondary)
            }

            Section("Sesión") {
                Toggle("Empezar los descansos solos", isOn: $settings.pomodoroAutoStartBreaks)
                Toggle("Empezar el foco solo tras el descanso", isOn: $settings.pomodoroAutoStartFocus)
                Picker("Avisar antes de terminar", selection: $settings.pomodoroWarning) {
                    ForEach(AppSettings.pomodoroWarnings, id: \.self) { seconds in
                        Text(seconds == 0 ? "No" : "\(seconds) s").tag(seconds)
                    }
                }
                Stepper(value: $settings.pomodoroDailyGoal, in: AppSettings.dailyGoals) {
                    Text("Objetivo del día: \(settings.pomodoroDailyGoal) pomodoros")
                }
            }

            Section {
                Toggle("Sonidos", isOn: $settings.pomodoroSound)
                Toggle("Bajar la música en el aviso", isOn: $settings.pomodoroDuckMusic)
                Stepper(value: $settings.pomodoroDuckLevel, in: AppSettings.duckLevels, step: 5) {
                    Text("Hasta el \(settings.pomodoroDuckLevel) % de tu volumen")
                }
                .disabled(!settings.pomodoroDuckMusic)
            } header: {
                Text("Avisos")
            } footer: {
                Text("Una nota de kalimba en el aviso, un cuenco al terminar el foco y dos notas al terminar el descanso. Si tocas el volumen mientras está bajado, se queda como lo dejes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!settings.showPomodoro)
    }
}

// Un preset del Pomodoro como tarjeta: su nombre y sus tiempos, resaltada si es el elegido
private struct PresetCard: View {
    let preset: PomodoroPreset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text(preset.name).font(.system(size: 12, weight: .semibold))
            if let minutes = preset.minutes {
                Text("\(minutes.focus) · \(minutes.shortBreak) · \(minutes.longBreak)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - Escritorios

private struct DesktopSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Señales automáticas", isOn: $settings.autoYabaiSignals)
            } header: {
                Text("yabai")
            } footer: {
                Text("YabaiBar le pide a yabai que la avise al crear, cerrar o minimizar ventanas y al cambiar los espacios o las pantallas, sin tocar tu yabairc. Si yabai se reinicia, las vuelve a añadir. Al apagarlo se quitan, también las de tu yabairc si usan las mismas etiquetas (yb_*), hasta que reinicies yabai.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Añadir los atajos de los escritorios nuevos", isOn: $settings.autoDesktopShortcuts)
            } header: {
                Text("Atajos de Mission Control")
            } footer: {
                Text("La isla te lleva a cada escritorio pulsando su atajo «Ir al escritorio N». Activado, los escritorios del 1 al 9 que no lo tengan lo reciben solos, con el mismo modificador que los demás (⌥5 si los otros son ⌥1…⌥4). Solo se añaden los que faltan, y la primera vez se guarda una copia de tus atajos en Preferencias.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Atajos

private struct ShortcutSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Atajo") {
                    ShortcutRecorder(
                        shortcut: $settings.toggleShortcut, defaultShortcut: .defaultToggle, error: settings.shortcutError,
                        settings: settings
                    )
                }
                LabeledContent("Trackpad", value: "3 o 4 dedos hacia abajo")
            } header: {
                Text("Abrir y cerrar la isla")
            } footer: {
                Text("Funcionan desde cualquier app. Para el gesto, App Exposé tiene que estar desactivado en Ajustes › Trackpad › Más gestos.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Atajo") {
                    ShortcutRecorder(
                        shortcut: $settings.pomodoroShortcut, defaultShortcut: .defaultPomodoro,
                        error: settings.pomodoroShortcutError, settings: settings
                    )
                }
                .disabled(!settings.showPomodoro)
            } header: {
                Text("Pomodoro")
            } footer: {
                Text(settings.showPomodoro
                    ? "Inicia, pausa o reanuda el Pomodoro desde cualquier app."
                    : "El Pomodoro está apagado: actívalo en la pestaña Isla para usar su atajo.")
                    .foregroundStyle(.secondary)
            }

            Section("En la isla") {
                LabeledContent("Esc", value: "Cierra la isla abierta con el atajo o el gesto")
                LabeledContent("Clic derecho", value: "Abre el menú")
                LabeledContent("Dos dedos de lado", value: "Cambian de canción sobre la música")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Acerca de

private struct AboutSettings: View {
    @State private var copied = false

    private static let repository = URL(string: "https://github.com/jerickgm89/yabaiDynamicIsland")!
    private static let issues = URL(string: "https://github.com/jerickgm89/yabaiDynamicIsland/issues")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Versión \(short) (\(build))"
    }

    // El Mac y el notch medido, como en «Primeros pasos»
    private var mac: String {
        let name = MacModels.model(for: MacModels.current)?.name ?? MacModels.current
        guard let notch = NSScreen.withNotch?.notchGeometry.notch.size else { return "\(name) · sin notch" }
        return "\(name) · notch de \(Int(notch.width.rounded())) × \(Int(notch.height.rounded())) pt"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    Text("YabaiBar").font(.title2.bold())
                    Text(version).foregroundStyle(.secondary)
                    Text(mac).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button(copied ? "Copiado" : "Copiar datos", action: copyReport)
                        Link("GitHub", destination: Self.repository)
                        Link("Informar de un problema", destination: Self.issues)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("Agradecimientos") {
                Text("El diseño de la isla se inspira en Atoll y en boring.notch. La música se lee con mediaremote-adapter. Y yabai hace posible todo lo demás.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // Lo mismo que copia «Primeros pasos», para pegarlo en un issue
    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SetupStatus.currentScreenReport(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
