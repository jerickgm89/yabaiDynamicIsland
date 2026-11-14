import AppKit
import SwiftUI

// El contenido de cada pestaña de los ajustes (SettingsWindow). Solo reordena los ajustes de AppSettings: la pestaña
// «Isla» reúne lo que se ve en la isla, con una vista previa que cambia al momento.
struct SettingsTabView: View {
    let tab: SettingsWindow.Tab
    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let claude: ClaudeConnection
    let calendar: CalendarStore
    let clipboard: ClipboardStore
    let maintenance: YabaiMaintenance
    let showWelcome: () -> Void

    var body: some View {
        switch tab {
        case .general: GeneralSettings(settings: settings, launchAtLogin: launchAtLogin, showWelcome: showWelcome)
        case .island: IslandSettings(settings: settings)
        case .music: MusicSettings(settings: settings)
        case .pomodoro: PomodoroSettings(settings: settings)
        case .desktops: DesktopSettings(settings: settings, maintenance: maintenance)
        case .utilities: UtilitySettings(settings: settings, calendar: calendar, clipboard: clipboard)
        case .developer: DeveloperSettings(settings: settings, claude: claude)
        case .shortcuts: ShortcutSettings(settings: settings)
        case .about: AboutSettings()
        }
    }
}

// MARK: - Utilidades

// El calendario de la pestaña Utilidades de la isla: el permiso, el aviso y qué calendarios se leen. El portapapeles y la bandeja
// sumarán lo suyo en las fases 43 y 44
private struct UtilitySettings: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarStore
    let clipboard: ClipboardStore

    var body: some View {
        Form {
            clipboardSection
            Section {
                LabeledContent("Acceso a Calendario") { accessLabel }
                accessButton
                Toggle("Avisar 5 minutos antes de cada evento", isOn: $settings.calendarNotice)
                    .disabled(calendar.access != .granted)
            } header: {
                Text("Calendario")
            } footer: {
                Text("La isla lee los eventos de la app Calendario (iCloud, Google y las demás cuentas que tengas allí) para enseñarte los del día en la pestaña Utilidades y avisarte antes de cada uno. Solo los lee: no los guarda ni los manda a ningún sitio, y los títulos no van a los registros. macOS pide el permiso una sola vez; si lo negaste, se cambia en Ajustes del Sistema › Privacidad y seguridad › Calendarios.")
                    .foregroundStyle(.secondary)
            }
            if calendar.access == .granted, !calendar.calendars.isEmpty {
                Section {
                    ForEach(calendar.calendars) { info in
                        Toggle(isOn: binding(for: info.id)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(red: info.color.red, green: info.color.green, blue: info.color.blue))
                                    .frame(width: 9, height: 9)
                                Text(info.title)
                                if !info.account.isEmpty {
                                    Text(info.account).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Calendarios que se ven")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { calendar.reload() }
    }

    // El historial del portapapeles: apagado hasta que se enciende, porque macOS pregunta antes de dejar que una app lea el
    // portapapeles sin que pegues. Las herramientas y el selector de color funcionan sin él
    @ViewBuilder private var clipboardSection: some View {
        Section {
            Toggle("Guardar un historial de lo que copio", isOn: Binding(
                get: { settings.clipboardHistory },
                set: { on in
                    if on { clipboard.requestAccess() } else { settings.clipboardHistory = false }
                }
            ))
            if settings.clipboardHistory {
                LabeledContent("Permiso de macOS") { clipboardAccessLabel }
                if clipboard.state == .needsAllow || clipboard.state == .denied {
                    Button("Abrir Ajustes del Sistema…") { clipboard.openPrivacySettings() }
                } else if clipboard.state == .needsFirstAccess {
                    Button("Dar acceso…") { clipboard.requestAccess() }
                }
                Toggle("Guardar el historial en el disco", isOn: $settings.clipboardPersist)
                Button("Borrar el historial") { clipboard.clearHistory() }
                    .disabled(clipboard.history.entries.isEmpty)
                DisclosureGroup("Apps que no se guardan (\(settings.clipboardIgnoredApps.count))") {
                    ForEach(settings.clipboardIgnoredApps, id: \.self) { id in
                        HStack {
                            Text(id).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                settings.clipboardIgnoredApps.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button("Añadir app…", action: addIgnoredApp)
                        Button("Restaurar la lista") { settings.clipboardIgnoredApps = ClipboardFilter.defaultIgnoredApps }
                    }
                }
            }
        } header: {
            Text("Portapapeles")
        } footer: {
            Text("Las herramientas de la isla (JSON, base64, URL, JWT, UUID, timestamp y SHA-256) y el cuentagotas funcionan siempre: leen el portapapeles solo cuando pulsas un botón. El historial apunta todo lo que copias: está apagado hasta que lo enciendes, vive en memoria (20 copias, 6 a la vista) y no guarda lo que las apps marcan como oculto (las contraseñas) ni lo de las apps de la lista. macOS pregunta antes de dejar que una app lea el portapapeles sin que pegues: para que el historial siga solo, elige «Permitir» para YabaiBar en Ajustes del Sistema › Privacidad y seguridad › Pegar desde otras apps. Guardarlo en disco deja un archivo con lo que copiaste en ~/Library/Application Support/YabaiBar, solo legible por ti.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var clipboardAccessLabel: some View {
        switch clipboard.state {
        case .recording: Label("Permitido", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsFirstAccess: Text("Sin pedir").foregroundStyle(.secondary)
        case .needsAllow: Label("Pregunta cada vez: elige «Permitir»", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .denied: Label("Denegado", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .off: EmptyView()
        }
    }

    /// Una app de la lista: se elige la `.app` y se guarda su identificador
    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "No guardar"
        panel.message = "Elige las apps de las que no se guardará lo que copies."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, BundleIdentifier.isValid(id), !settings.clipboardIgnoredApps.contains(id) else { continue }
            settings.clipboardIgnoredApps.append(id)
        }
    }

    @ViewBuilder private var accessLabel: some View {
        switch calendar.access {
        case .granted: Label("Concedido", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notDetermined: Text("Sin pedir").foregroundStyle(.secondary)
        case .denied: Label("Denegado", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var accessButton: some View {
        switch calendar.access {
        case .granted: EmptyView()
        case .notDetermined: Button("Dar acceso…") { Task { await calendar.requestAccess() } }
        case .denied: Button("Abrir Ajustes del Sistema…") { calendar.openPrivacySettings() }
        }
    }

    // Visto o no: se guarda lo que se excluye, así un calendario nuevo se ve desde el principio
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.calendarExcluded.contains(id) },
            set: { visible in
                if visible {
                    settings.calendarExcluded.removeAll { $0 == id }
                } else if !settings.calendarExcluded.contains(id) {
                    settings.calendarExcluded.append(id)
                }
            }
        )
    }
}

// MARK: - Desarrollador

// Los módulos de la pestaña Desarrollador de la isla que se pueden apagar. Se irán sumando con cada módulo
private struct DeveloperSettings: View {
    @Bindable var settings: AppSettings
    let claude: ClaudeConnection

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar los contenedores de Docker", isOn: $settings.showDocker)
                Toggle("Mostrar Git y GitHub", isOn: $settings.showGit)
            } header: {
                Text("Módulos")
            } footer: {
                Text("Con un módulo apagado, desaparece de la pestaña Desarrollador y no se consulta nada. Cerrar un proceso o parar un contenedor siempre pide confirmación antes.")
                    .foregroundStyle(.secondary)
            }
            gitSection
            terminalSection
            claudeSection
        }
        .formStyle(.grouped)
        .onAppear { claude.refresh() }
    }

    // Qué repositorios se vigilan y qué avisa la isla cerrada. Solo informa: YabaiBar nunca hace commit, push, fetch ni crea etiquetas
    @ViewBuilder private var gitSection: some View {
        Section {
            if settings.gitFolders.isEmpty {
                Text("Solo los repositorios de las sesiones de Claude Code abiertas.").foregroundStyle(.secondary)
            }
            ForEach(settings.gitFolders, id: \.self) { folder in
                HStack {
                    Text((folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        settings.gitFolders.removeAll { $0 == folder }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Dejar de vigilar esta carpeta")
                }
            }
            Button("Añadir carpeta…", action: addFolder)
            Toggle("Consultar GitHub con gh", isOn: $settings.gitUseGitHub)
            Toggle("Avisar de commits sin subir", isOn: $settings.gitNoticeUnpushed)
            Picker("…tras", selection: $settings.gitUnpushedMinutes) {
                ForEach(AppSettings.gitUnpushedMinutesOptions, id: \.self) { Text("\($0) min").tag($0) }
            }
            .disabled(!settings.gitNoticeUnpushed)
            Toggle("Avisar de cambios sin commit cuando Claude termina", isOn: $settings.gitNoticeUncommitted)
            Toggle("Avisar de una etiqueta sin release", isOn: $settings.gitNoticeUnreleased)
            Toggle("Avisar cuando termina el CI de un push", isOn: $settings.gitNoticeCI)
        } header: {
            Text("Git y GitHub")
        } footer: {
            Text("El módulo vigila, con el sistema y sin leer nada mientras no cambia, los repositorios de las sesiones de Claude Code abiertas y las carpetas que añadas. Solo informa: nunca hace commit, push, fetch ni crea etiquetas. GitHub se consulta con la sesión de gh, que no se copia en ningún sitio: las releases, el CI del último push y los PR abiertos. Si gh falla (sin red o sin sesión), el módulo no dice nada de eso en vez de adivinarlo.")
                .foregroundStyle(.secondary)
        }
    }

    // Los avisos de la terminal los manda `yb` desde unos hooks de zsh que el usuario carga desde ~/.zshrc: YabaiBar no toca ese
    // archivo, solo da la línea para copiarla
    @ViewBuilder private var terminalSection: some View {
        Section {
            Toggle("Avisar cuando termina un comando largo", isOn: $settings.terminalNotices)
            Picker("…si tarda más de", selection: $settings.terminalMinSeconds) {
                ForEach(AppSettings.terminalMinSecondsOptions, id: \.self) { Text("\($0) s").tag($0) }
            }
            .disabled(!settings.terminalNotices)
            Toggle("Avisar aunque la terminal esté delante", isOn: $settings.terminalWhenFrontmost)
                .disabled(!settings.terminalNotices)
            LabeledContent("En ~/.zshrc") {
                Button("Copiar la línea") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ZshHook.initLine(executable: ClaudeConnection.helperPath), forType: .string)
                }
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("Pega la línea en ~/.zshrc y abre una terminal nueva: al volver al prompt tras un comando largo, zsh se lo avisa a YabaiBar con yb (YB_AVISO_MIN cambia los segundos en la shell y el mínimo de arriba también cuenta: manda el más alto. YB_AVISO_IGNORE sustituye la lista de programas que no avisan, y YB_AVISO_IGNORE_EXTRA le añade; vim, ssh, tail, claude y similares ya no avisan). Solo viaja el nombre del programa, el código de salida y lo que tardó, nunca la línea entera. YabaiBar no toca tu ~/.zshrc. Desde un script, «yb aviso \"título\" \"detalle\" --ok» enseña un aviso a mano. Con yb en el PATH (el cask de Homebrew lo enlaza) la línea queda como eval \"$(yb shell-init zsh)\".")
                .foregroundStyle(.secondary)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Vigilar"
        panel.message = "Elige carpetas que sean un repositorio de git (o estén dentro de uno)."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.gitFolders.contains(url.path) { settings.gitFolders.append(url.path) }
    }

    // Las sesiones abiertas se ven sin configurar nada. Los avisos de «Claude pregunta» necesitan los hooks en el settings.json
    // de Claude Code, y esos solo se añaden desde aquí, con una confirmación
    private var claudeSection: some View {
        Section {
            LabeledContent("Avisos de preguntas") {
                switch claude.status {
                case .connected: Label("Conectado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .outdated: Label("Hay que volver a conectar", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .notConnected: Text("Sin conectar").foregroundStyle(.secondary)
                case nil: Text("…").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(claude.status == .outdated ? "Volver a conectar…" : "Conectar con Claude Code…") { claude.connect() }
                    .disabled(claude.status == .connected)
                Button("Quitar los hooks…") { claude.disconnect() }
                    .disabled(claude.status == .notConnected || claude.status == nil)
            }
            if let error = claude.lastError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Toggle("Avisar cuando Claude termine algo largo", isOn: $settings.claudeNotifyFinished)
        } header: {
            Text("Claude Code")
        } footer: {
            Text("La isla enseña las sesiones abiertas leyendo ~/.claude/sessions. Para avisarte cuando Claude te pregunta algo, YabaiBar añade cinco hooks a ~/.claude/settings.json: mandan el nombre del evento, el id y la carpeta de la sesión y, en una pregunta, lo que Claude Code dice, nunca lo que escribes ni lo que responde Claude. Antes de tocar el archivo se guarda una copia (el archivo se reescribe entero, con las claves ordenadas), y «Quitar» solo borra lo que añadió YabaiBar. Las sesiones que ya estaban abiertas necesitan reiniciarse para leer los hooks nuevos. No se ven los chats normales de la app de Claude, solo las sesiones de Claude Code.")
                .foregroundStyle(.secondary)
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
                Text("En la isla abierta, pestaña Utilidades")
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

// La pestaña Utilidades de la isla abierta en miniatura con lo que está activado: las píldoras de las pestañas, la taza
// y el engranaje de arriba, y la fila de la música y el Pomodoro. No es la isla real: solo enseña qué partes se ven
private struct IslandPreview: View {
    let music: Bool
    let pomodoro: Bool
    let cup: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.16, green: 0.43, blue: 0.42))
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(IslandTab.allCases, id: \.self) { tab in
                        Image(systemName: tab.symbol)
                            .foregroundStyle(.white.opacity(tab == .utilities ? 1 : 0.6))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.white.opacity(tab == .utilities ? 0.2 : 0)))
                    }
                    Spacer()
                    if cup { Image(systemName: "cup.and.saucer.fill").foregroundStyle(.white.opacity(0.6)) }
                    Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 20)
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
                } else {
                    Text("No suena nada ahora")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(height: 46)
                }
                // La segunda fila: el calendario, el portapapeles y la bandeja, que llegan en próximas versiones
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08))
                    }
                }
                .frame(height: 22)
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
    let maintenance: YabaiMaintenance

    var body: some View {
        Form {
            panelSection
            yabaiSection
            Section {
                Toggle("Añadir los atajos de los escritorios nuevos", isOn: $settings.autoDesktopShortcuts)
            } header: {
                Text("Atajos de Mission Control")
            } footer: {
                Text("La isla te lleva a cada escritorio pulsando su atajo «Ir al escritorio N». Activado, los escritorios del 1 al 9 que no lo tengan lo reciben solos, con el mismo modificador que los demás (⌥5 si los otros son ⌥1…⌥4). Solo se añaden los que faltan, y la primera vez se guarda una copia de tus atajos en Preferencias.")
                    .foregroundStyle(.secondary)
            }
            rememberedSection
            floatSection
            skhdSection
        }
        .formStyle(.grouped)
        .task { await maintenance.refreshStatus() }
    }

    // Los controles de yabai debajo de las tarjetas de la isla, y cómo se cambia de escritorio con un clic
    private var panelSection: some View {
        Section {
            Toggle("Mostrar los controles de yabai en la isla", isOn: $settings.showDesktopPanel)
            Toggle("Cambiar de escritorio al instante", isOn: $settings.instantSwitch)
                .disabled(!maintenance.scriptingAddition)
        } header: {
            Text("Escritorios en la isla")
        } footer: {
            Text("El panel enseña las ventanas del escritorio activo y los botones de yabai (distribución, ventana enfocada, escritorios), y solo consulta a yabai con la pestaña Escritorios a la vista. Cambiar al instante usa «space --focus» de yabai, sin la animación de macOS; necesita la scripting addition. Sin ella, la isla sigue usando el atajo ⌥N.")
                .foregroundStyle(.secondary)
        }
    }

    private var yabaiSection: some View {
        Section {
            Toggle("Señales automáticas", isOn: $settings.autoYabaiSignals)
            LabeledContent("Versión", value: maintenance.version ?? "—")
            LabeledContent("Scripting addition", value: maintenance.scriptingAddition ? "Cargada" : "No cargada")
            Button(maintenance.isRestarting ? "Reiniciando…" : "Reiniciar yabai…") { maintenance.restart() }
                .disabled(maintenance.isRestarting)
            if maintenance.restartFailed {
                Text("No se pudo reiniciar yabai. Si el servicio está parado, arráncalo con «yabai --start-service».").foregroundStyle(.orange)
            }
        } header: {
            Text("yabai")
        } footer: {
            Text("YabaiBar le pide a yabai que la avise al crear, cerrar o minimizar ventanas y al cambiar los espacios o las pantallas, sin tocar tu yabairc. Si yabai se reinicia, las vuelve a añadir. Al apagarlo se quitan, también las de tu yabairc si usan las mismas etiquetas (yb_*), hasta que reinicies yabai. Mover escritorios, cambiar al instante y fijar una ventana necesitan la scripting addition, que carga el usuario con «sudo yabai --load-sa»; YabaiBar nunca lo hace. Reiniciar yabai pide confirmación.")
                .foregroundStyle(.secondary)
        }
    }

    // La distribución que elegiste en la isla para cada escritorio, que yabai pierde al reiniciarse y la app vuelve a poner
    @ViewBuilder private var rememberedSection: some View {
        let remembered = LayoutMemory.decode(settings.rememberedLayouts)
        Section {
            if remembered.isEmpty {
                Text("Nada recordado todavía: lo que elijas con los botones de distribución de la isla.").foregroundStyle(.secondary)
            }
            ForEach(remembered.keys.sorted(), id: \.self) { index in
                HStack {
                    Text("Escritorio \(index)")
                    Spacer()
                    Text(remembered[index]?.title ?? "").foregroundStyle(.secondary)
                    Button("Olvidar") { maintenance.forgetLayout(of: index) }
                }
            }
            if remembered.count > 1 {
                Button("Olvidar todas") { maintenance.forgetAllLayouts() }
            }
        } header: {
            Text("Distribución recordada")
        } footer: {
            Text("Cuando yabai se reinicia, la app vuelve a poner la distribución de los escritorios donde la cambiaste desde la isla. Se guarda por número de escritorio.")
                .foregroundStyle(.secondary)
        }
    }

    // Las apps que siempre flotan: una regla de yabai (manage=off) que la app vuelve a añadir cuando yabai se reinicia
    @ViewBuilder private var floatSection: some View {
        Section {
            if settings.floatApps.isEmpty {
                Text("Ninguna: se añaden con el botón «Esta app, siempre flotante» de la ventana enfocada en la isla.").foregroundStyle(.secondary)
            }
            ForEach(settings.floatApps, id: \.self) { app in
                HStack {
                    Text(app).lineLimit(1)
                    Spacer()
                    Button("Quitar") { maintenance.removeFloatApp(app) }
                }
            }
        } header: {
            Text("Apps siempre flotantes")
        } footer: {
            Text("Sus ventanas no se colocan en el mosaico. Se aplican a las ventanas nuevas y, al añadirlas, a las que ya hay.")
                .foregroundStyle(.secondary)
        }
    }

    // Los atajos de ~/.config/skhd/skhdrc, agrupados por sus comentarios y en solo lectura: YabaiBar nunca escribe en él
    @ViewBuilder private var skhdSection: some View {
        Section {
            if let groups = maintenance.cheatSheet {
                ForEach(groups) { group in
                    DisclosureGroup("\(group.title) (\(group.bindings.count))") {
                        ForEach(Array(group.bindings.enumerated()), id: \.offset) { _, binding in
                            HStack(alignment: .firstTextBaseline) {
                                Text(binding.keys).font(.system(.body, design: .monospaced)).frame(width: 110, alignment: .leading)
                                Text(binding.command).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            } else {
                Text("No hay un skhdrc en ~/.config/skhd.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Chuleta de skhd")
        } footer: {
            Text("Solo lectura. Para cambiarlos, edita el archivo.")
                .foregroundStyle(.secondary)
        }
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
