import CoreGraphics
import Foundation
import Testing
@testable import YabaiBar

@MainActor
struct DevToolsTests {
    private func make(docker: Bool = true) throws -> (tools: DevTools, settings: AppSettings) {
        let defaults = UserDefaults(suiteName: "devtools-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.showDocker = docker
        // Sin programa de Docker: el módulo mide «no instalado» sin lanzar nada
        let tools = DevTools(
            system: SystemMonitor(), ports: PortsMonitor(), docker: DockerMonitor(executable: nil),
            claude: try ClaudeTestSupport.sessions(), git: GitMonitor(git: nil, gh: nil, settings: settings), notices: NoticeLog(), settings: settings
        )
        return (tools, settings)
    }

    // Nada consulta salvo con la pestaña Desarrollador a la vista
    @Test func onlyTheDeveloperTabKeepsTheModulesRunning() throws {
        let (tools, _) = try make()
        #expect(!tools.isPolling)
        for hidden in [IslandTab.desktops, .utilities] {
            tools.setVisibleTab(hidden)
            #expect(!tools.isPolling, "\(hidden)")
        }
        tools.setVisibleTab(.developer)
        #expect(tools.system.isRunning && tools.ports.isRunning && tools.docker.isRunning)
        // Repetirlo no arranca otro
        tools.setVisibleTab(.developer)
        #expect(tools.isPolling)
        tools.setVisibleTab(.utilities)
        #expect(!tools.system.isRunning && !tools.ports.isRunning && !tools.docker.isRunning)
        // Con la isla cerrada, ninguna pestaña a la vista
        tools.setVisibleTab(.developer)
        tools.setVisibleTab(nil)
        #expect(!tools.isPolling)
    }

    // Docker apagado en Ajustes: ni se ve ni se consulta
    @Test func dockerTurnedOffInSettingsIsNotQueried() throws {
        let (tools, _) = try make(docker: false)
        tools.setVisibleTab(.developer)
        #expect(tools.system.isRunning && tools.ports.isRunning)
        #expect(!tools.docker.isRunning)
        #expect(tools.rowsContent()[.docker] == nil)
        #expect(tools.rowsContent()[.ports] != nil)
        tools.setVisibleTab(nil)
    }

    // Git apagado en Ajustes: el módulo no se ve. Encendido, dice por qué no hay filas (aquí, sin programa de git) en vez de quedarse
    // en blanco
    @Test func theGitModuleFollowsItsSetting() throws {
        let (tools, settings) = try make()
        #expect(tools.rowsContent()[.git]?.notice?.title == "No se encuentra git")
        settings.showGit = false
        #expect(tools.rowsContent()[.git] == nil)
        #expect(tools.rowsContent()[.docker] != nil)
    }

    // Git vigila con la isla cerrada, por eventos: que la pestaña se vea no lo arranca si no está en marcha, y no cuenta como consulta
    @Test func theGitMonitorDoesNotCountAsPollingUntilItAsksGitHub() throws {
        let (tools, _) = try make()
        tools.setVisibleTab(.developer)
        #expect(!tools.git.isRunning)
        tools.setVisibleTab(nil)
        #expect(!tools.isPolling)
    }

    // Con la pestaña a la vista, encender o apagar Docker en Ajustes arranca o para el módulo al momento
    @Test func switchingDockerInSettingsWhileVisibleStartsOrStopsIt() async throws {
        let (tools, settings) = try make()
        tools.setVisibleTab(.developer)
        #expect(tools.docker.isRunning)
        settings.showDocker = false
        try await Task.sleep(for: .milliseconds(200))
        #expect(!tools.docker.isRunning)
        settings.showDocker = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(tools.docker.isRunning)
        tools.setVisibleTab(nil)
        #expect(!tools.isPolling)
    }

    // Al cerrarse la pestaña se borra lo medido: al volver no se ve una medida de hace horas
    @Test func closingTheTabClearsWhatWasMeasured() async throws {
        let (tools, _) = try make()
        tools.setVisibleTab(.developer)
        var waited = 0
        while tools.docker.state == nil && waited < 30 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        #expect(tools.docker.state == .notInstalled)
        #expect(tools.rowsContent()[.docker]?.notice?.title == "Docker no está instalado")
        tools.setVisibleTab(nil)
        #expect(tools.docker.state == nil && tools.ports.listeners == nil)
    }
}

struct ModuleRowLayoutTests {
    private let cell = CGSize(width: 240, height: 112)

    // El margen de 10 y la cabecera de 14 con 6 de hueco: las filas empiezan en y = 30 y miden 22
    @Test func rowsStackBelowTheHeader() {
        #expect(ModuleRowLayout.rowFrame(0, in: cell) == CGRect(x: 10, y: 30, width: 220, height: 22))
        #expect(ModuleRowLayout.rowFrame(1, in: cell) == CGRect(x: 10, y: 52, width: 220, height: 22))
        #expect(ModuleRowLayout.rowFrame(2, in: cell) == CGRect(x: 10, y: 74, width: 220, height: 22))
        // Con 3 filas queda 6 pt libres antes del margen de abajo (112 - 10 = 102)
        #expect(ModuleRowLayout.rowFrame(2, in: cell).maxY == 96)
    }

    @Test(arguments: [(29.9, nil as Int?), (30.0, 0), (51.9, 0), (52.0, 1), (95.9, 2), (96.0, nil)])
    func findsTheRowAtAHeight(y: Double, row: Int?) {
        #expect(ModuleRowLayout.rowIndex(at: CGPoint(x: 50, y: y), rowCount: 3, cell: cell) == row)
    }

    @Test func rowsThatDoNotExistAreNotFound() {
        #expect(ModuleRowLayout.rowIndex(at: CGPoint(x: 50, y: 60), rowCount: 1, cell: cell) == nil)
        // Los márgenes de los lados
        #expect(ModuleRowLayout.rowIndex(at: CGPoint(x: 5, y: 40), rowCount: 3, cell: cell) == nil)
        // Nunca más de 3, aunque haya más datos
        #expect(ModuleRowLayout.rowIndex(at: CGPoint(x: 50, y: 100), rowCount: 5, cell: cell) == nil)
    }

    // Tres botones de 20 con 2 de separación son 64 pt, pegados a la derecha de la fila con 2 de margen: x = 230 - 2 - 64
    @Test func buttonsAreFlushWithTheRightEdge() {
        let row = ModuleRowLayout.rowFrame(0, in: cell)
        let frames = ModuleRowLayout.buttonFrames(actionCount: 3, in: row)
        #expect(frames == [
            CGRect(x: 164, y: 31, width: 20, height: 20),
            CGRect(x: 186, y: 31, width: 20, height: 20),
            CGRect(x: 208, y: 31, width: 20, height: 20),
        ])
        #expect(ModuleRowLayout.buttonFrames(actionCount: 1, in: row) == [CGRect(x: 208, y: 31, width: 20, height: 20)])
        #expect(ModuleRowLayout.buttonFrames(actionCount: 0, in: row).isEmpty)
    }
}

// Pestaña Desarrollador con 4 escritorios y el notch de 38 pt: cuerpo de 770, isla de 808, rejilla de 742 pt que empieza en
// (33, 46) con tres columnas de 240,67. El módulo Puertos es la segunda columna (empieza en x = 250,67), así que su
// primera fila está en x = 33 + 250,67 + 10 = 293,67 y y = 46 + 30 = 76, de 220,67 × 22. Sus tres botones empiezan en
// x = 293,67 + 220,67 - 2 - 64 = 448,33 y están centrados en alto en y = 87: abrir en 458, copiar en 480 y cerrar en 502
struct ModuleRowHitTests {
    private func layout(_ tab: IslandTab = .developer) -> IslandExpandedLayout {
        IslandExpandedLayout(
            spaces: (1...4).map { SpaceSummary(index: $0, isFocused: $0 == 1, apps: []) }, minBodyWidth: 396,
            maxBodyWidth: 1958, topHeight: 38, tab: tab, tabs: IslandTab.allCases, hasKeepAwake: true, hasSettingsButton: true
        )
    }

    private let row = ModuleRow(id: "100:3000", leading: .code(":3000"), title: "node", actions: [.open, .copy, .close])
    private var rows: [ModuleID: [ModuleRow]] { [.ports: [row]] }

    private func control(_ x: CGFloat, _ y: CGFloat, tab: IslandTab = .developer) -> ModuleControl? {
        layout(tab).moduleControl(at: CGPoint(x: x, y: y), islandWidth: 808, topHeight: 38, rows: rows)
    }

    @Test func findsEachButtonOfARow() {
        #expect(control(458, 87) == ModuleControl(module: .ports, row: "100:3000", action: .open))
        #expect(control(480, 87) == ModuleControl(module: .ports, row: "100:3000", action: .copy))
        #expect(control(502, 87) == ModuleControl(module: .ports, row: "100:3000", action: .close))
    }

    @Test func theRestOfTheRowIsNotAButtonButItIsTheRow() {
        #expect(control(330, 87) == nil)
        let hit = layout().moduleRow(at: CGPoint(x: 330, y: 87), islandWidth: 808, topHeight: 38, rows: rows)
        #expect(hit?.module == .ports && hit?.row.id == "100:3000")
        // La cabecera del módulo y lo que queda debajo de las filas no son filas
        #expect(layout().moduleRow(at: CGPoint(x: 330, y: 70), islandWidth: 808, topHeight: 38, rows: rows) == nil)
        #expect(layout().moduleRow(at: CGPoint(x: 330, y: 110), islandWidth: 808, topHeight: 38, rows: rows) == nil)
    }

    // Un módulo sin filas, o la columna de otro módulo, no responde
    @Test func otherModulesAndOtherTabsDoNotRespond() {
        #expect(control(100, 87) == nil)
        #expect(layout().moduleControl(at: CGPoint(x: 502, y: 87), islandWidth: 808, topHeight: 38, rows: [:]) == nil)
        for tab in [IslandTab.desktops, .utilities] {
            #expect(control(502, 87, tab: tab) == nil)
            #expect(layout(tab).moduleRow(at: CGPoint(x: 330, y: 87), islandWidth: 808, topHeight: 38, rows: rows) == nil)
        }
    }

    // Una fila sin botones no tiene nada que pulsar
    @Test func aRowWithoutActionsHasNoControl() {
        let plain = ModuleRow(id: "x", title: "Ninguno en marcha")
        #expect(layout().moduleControl(at: CGPoint(x: 502, y: 87), islandWidth: 808, topHeight: 38, rows: [.ports: [plain]]) == nil)
    }
}
