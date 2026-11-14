import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import YabaiBar

// El módulo Bandeja de Utilidades (fase 44): las reglas de la lista, dónde está cada cosa, el almacén con archivos temporales de verdad
// (marcador, renombrar, borrar) y el manejo de lo que se arrastra sobre la isla. Nunca se tocan archivos del usuario: todo vive en
// carpetas temporales de cada prueba, y `UserDefaults` es un dominio propio.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func drop(_ path: String, bookmark: Data? = nil) -> TrayDrop {
    TrayDrop(path: path, bookmark: bookmark)
}

struct TrayShelfTests {
    @Test func theFirstDroppedIsOnTop() {
        var shelf = TrayShelf()
        let added = shelf.add([drop("/a/uno"), drop("/a/dos"), drop("/a/tres")], at: now)
        #expect(added == 3)
        #expect(shelf.items.map(\.path) == ["/a/uno", "/a/dos", "/a/tres"])
        // Lo siguiente que se suelta queda por encima
        shelf.add([drop("/a/cuatro")], at: now.addingTimeInterval(1))
        #expect(shelf.items.map(\.path) == ["/a/cuatro", "/a/uno", "/a/dos", "/a/tres"])
    }

    @Test func aRepeatedFileGoesToTheTopInsteadOfAppearingTwice() {
        var shelf = TrayShelf()
        shelf.add([drop("/a/uno"), drop("/a/dos")], at: now)
        shelf.add([drop("/a/dos")], at: now.addingTimeInterval(5))
        #expect(shelf.items.map(\.path) == ["/a/dos", "/a/uno"])
        #expect(shelf.items.first?.added == now.addingTimeInterval(5))
        // Repetido dentro de una misma suelta: cuenta una vez
        var other = TrayShelf()
        #expect(other.add([drop("/b/x"), drop("/b/x"), drop("/b/y")], at: now) == 2)
        #expect(other.items.map(\.path) == ["/b/x", "/b/y"])
    }

    @Test func onlyTwelveAreKeptAndTheOldestLeave() {
        var shelf = TrayShelf()
        for index in 0..<15 { shelf.add([drop("/a/archivo\(index)")], at: now) }
        #expect(shelf.items.count == 12)
        #expect(shelf.items.first?.path == "/a/archivo14" && shelf.items.last?.path == "/a/archivo3")
        // Una suelta de más de 12 no pasa del límite
        var big = TrayShelf()
        #expect(big.add((0..<30).map { drop("/c/\($0)") }, at: now) == 12)
        #expect(big.items.count == 12 && big.items.first?.path == "/c/0")
    }

    @Test(arguments: ["", "relativa/ruta", "/", "sin-barra", "/con\0nulo"])
    func pathsThatAreNotFilesAreRefused(path: String) {
        var shelf = TrayShelf()
        #expect(shelf.add([drop(path)], at: now) == 0 && shelf.items.isEmpty)
        #expect(!TrayShelf.isValid(path: path))
    }

    @Test func aHugePathIsRefused() {
        let huge = "/" + String(repeating: "a", count: TrayShelf.maxPathLength)
        #expect(!TrayShelf.isValid(path: huge))
        #expect(TrayShelf.isValid(path: "/" + String(repeating: "a", count: 100)))
    }

    @Test func removingOneKeepsTheRest() {
        var shelf = TrayShelf()
        shelf.add([drop("/a/uno"), drop("/a/dos")], at: now)
        let first = shelf.items[0].id
        shelf.remove(id: first)
        #expect(shelf.items.map(\.path) == ["/a/dos"])
        shelf.remove(id: "no-existe")
        #expect(shelf.items.count == 1)
        shelf.clear()
        #expect(shelf.items.isEmpty)
    }

    // Lo guardado en disco pasa por las mismas reglas que lo que se suelta ahora
    @Test func storedItemsFollowTheSameRules() {
        let items = [
            TrayItem(id: "a", path: "/a/uno", bookmark: nil, added: now), TrayItem(id: "a", path: "/a/dos", bookmark: nil, added: now),
            TrayItem(id: "b", path: "/a/uno", bookmark: nil, added: now), TrayItem(id: "c", path: "relativa", bookmark: nil, added: now),
            TrayItem(id: "d", path: "/a/tres", bookmark: nil, added: now),
        ]
        let shelf = TrayShelf(items: items)
        #expect(shelf.items.map(\.path) == ["/a/uno", "/a/dos", "/a/tres"])
        #expect(Set(shelf.items.map(\.id)).count == 3)
        let many = TrayShelf(items: (0..<30).map { TrayItem(path: "/m/\($0)", bookmark: nil, added: now) })
        #expect(many.items.count == 12)
    }

    // MARK: Rutas y nombres

    @Test func aFileURLBecomesAStandardPath() {
        #expect(TrayShelf.path(of: URL(fileURLWithPath: "/a/b/../c/archivo.txt")) == "/a/c/archivo.txt")
        #expect(TrayShelf.path(of: URL(fileURLWithPath: "/a/carpeta/")) == "/a/carpeta")
        #expect(TrayShelf.path(of: URL(fileURLWithPath: "/")) == nil)
    }

    @Test func onlyLocalFilesAreAccepted() throws {
        #expect(TrayShelf.path(of: try #require(URL(string: "https://example.com/archivo.pdf"))) == nil)
        #expect(TrayShelf.path(of: try #require(URL(string: "ftp://example.com/a"))) == nil)
        #expect(TrayShelf.path(of: try #require(URL(string: "file:///tmp/x.txt"))) != nil)
        #expect(TrayShelf.path(of: try #require(URL(string: "file://localhost/tmp/x.txt"))) == "/tmp/x.txt")
        // Con el nombre de otro equipo no es un archivo de este
        #expect(TrayShelf.path(of: try #require(URL(string: "file://otro-equipo/etc/hosts"))) == nil)
    }

    @Test func theDisplayNameHasNothingInvisible() {
        #expect(TrayShelf.displayName(of: "/a/b/informe.pdf") == "informe.pdf")
        #expect(TrayShelf.displayName(of: "/a/b/dos\nlíneas\t.txt") == "dos líneas .txt")
        #expect(TrayShelf.displayName(of: "/a/b/\u{7}\u{7}") == "(sin nombre)")
        #expect(TrayItem(path: "/a/b/c.md", bookmark: nil, added: now).name == "c.md")
    }

    // MARK: Lo que se movió o falta

    @Test func aMovedFileFollowsItsNewPath() {
        var shelf = TrayShelf()
        shelf.add([drop("/a/viejo.txt"), drop("/a/otro.txt")], at: now)
        let id = shelf.items[0].id
        let fresh = Data([1, 2, 3])
        shelf.apply([TrayResolution(id: id, path: "/b/nuevo.txt", bookmark: fresh)])
        #expect(shelf.items.map(\.path) == ["/b/nuevo.txt", "/a/otro.txt"])
        #expect(shelf.items[0].bookmark == fresh)
        // Un elemento que llegó al mismo archivo que otro: queda uno
        let second = shelf.items[1].id
        shelf.apply([TrayResolution(id: second, path: "/b/nuevo.txt", bookmark: nil)])
        #expect(shelf.items.map(\.path) == ["/b/nuevo.txt"])
    }

    @Test func missingMeansNoPath() {
        let found = TrayResolution(id: "a", path: "/a/x", bookmark: nil)
        let lost = TrayResolution(id: "b", path: nil, bookmark: nil)
        #expect(TrayShelf.missing([found, lost]) == ["b"])
        // Una ruta que no vale no se aplica
        var shelf = TrayShelf()
        shelf.add([drop("/a/x")], at: now)
        shelf.apply([TrayResolution(id: shelf.items[0].id, path: "relativa", bookmark: nil)])
        #expect(shelf.items.map(\.path) == ["/a/x"])
    }

    @Test func theSnapshotMarksWhatIsMissing() {
        var shelf = TrayShelf()
        shelf.add([drop("/a/uno"), drop("/a/dos")], at: now)
        let snapshot = TraySnapshot.make(shelf: shelf, missing: [shelf.items[1].id], verified: [shelf.items[0].id])
        #expect(snapshot.items.map(\.isMissing) == [false, true])
        #expect(snapshot.items.map(\.isVerified) == [true, false])
        #expect(snapshot.items.map(\.name) == ["uno", "dos"])
    }
}

struct TrayLayoutTests {
    private let size = CGSize(width: 152, height: 112)

    @Test func fourColumnsFitInTheModuleOfThe16Inch() {
        #expect(TrayModuleLayout.columns(in: size) == 4)
        #expect(TrayModuleLayout.slotCount(in: size) == TrayShelf.capacity)
        // Más estrecho, menos columnas; nunca cero
        #expect(TrayModuleLayout.columns(in: CGSize(width: 100, height: 112)) == 2)
        #expect(TrayModuleLayout.columns(in: CGSize(width: 10, height: 112)) == 1)
        #expect(TrayModuleLayout.columns(in: CGSize(width: 900, height: 112)) == TrayModuleLayout.maxColumns)
    }

    @Test func theIconsStayInsideTheModuleAndDoNotOverlap() {
        for width in [120.0, 152, 180, 240] {
            let box = CGSize(width: width, height: 112)
            let frames = (0..<TrayModuleLayout.slotCount(in: box)).map { TrayModuleLayout.itemFrame($0, in: box) }
            let bounds = CGRect(origin: .zero, size: box)
            for (index, frame) in frames.enumerated() {
                #expect(bounds.contains(frame), "\(width) pt, ícono \(index)")
                #expect(frame.width > 0 && frame.height > 0)
                for other in frames[(index + 1)...] { #expect(!frame.intersects(other.insetBy(dx: 0.01, dy: 0.01)), "\(width) pt") }
            }
        }
    }

    // Con un módulo absurdamente estrecho o bajo, nada sale con medidas negativas
    @Test func aTinyModuleNeverGivesNegativeFrames() {
        for box in [CGSize(width: 10, height: 112), CGSize(width: 152, height: 20), .zero] {
            for slot in 0..<TrayModuleLayout.slotCount(in: box) {
                let frame = TrayModuleLayout.itemFrame(slot, in: box)
                #expect(frame.width >= 0 && frame.height >= 0, "\(box)")
            }
        }
    }

    @Test func theRemoveButtonIsInTheCornerOfItsIcon() {
        for slot in 0..<12 {
            let item = TrayModuleLayout.itemFrame(slot, in: size)
            let remove = TrayModuleLayout.removeFrame(slot, in: size)
            #expect(item.contains(remove))
            #expect(remove.maxX == item.maxX && remove.minY == item.minY)
        }
    }

    // La «×» se resuelve antes que el ícono, y todo por identificador
    @Test func clicksResolveByIdentifier() {
        let ids = ["a", "b", "c"]
        func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        func control(_ point: CGPoint, ids: [String] = ids) -> TrayControl? { TrayModuleLayout.control(at: point, ids: ids, in: size) }
        #expect(control(center(TrayModuleLayout.itemFrame(1, in: size))) == .item("b"))
        #expect(control(center(TrayModuleLayout.removeFrame(2, in: size))) == .remove("c"))
        // Una celda sin archivo, la cabecera y fuera del módulo no responden
        #expect(control(center(TrayModuleLayout.itemFrame(3, in: size))) == nil)
        #expect(control(CGPoint(x: 20, y: 10)) == nil && control(CGPoint(x: -5, y: -5)) == nil)
        // Si la lista cambia entre que se vio y se pulsó, lo pulsado sigue siendo lo que había en esa celda de la lista nueva
        #expect(control(center(TrayModuleLayout.itemFrame(0, in: size)), ids: ["z"]) == .item("z"))
    }

    @Test func theBodyIsWhereYouDrop() {
        let body = TrayModuleLayout.bodyFrame(in: size)
        #expect(CGRect(origin: .zero, size: size).contains(body))
        #expect(body.minY >= TrayModuleLayout.bodyY)
    }

    private func layout(_ tab: IslandTab) -> IslandExpandedLayout {
        IslandExpandedLayout(
            spaces: [SpaceSummary(index: 1, isFocused: true, apps: [])], minBodyWidth: 396, maxBodyWidth: 1958, topHeight: 38, tab: tab,
            tabs: IslandTab.allCases, developerModules: ModuleID.modules(of: .developer), hasMedia: true, hasKeepAwake: true,
            hasPomodoro: true, hasSettingsButton: true
        )
    }

    // Con la isla de verdad: solo en Utilidades, junto al portapapeles y con ícono para 12
    @Test func theIslandResolvesTrayClicksOnlyInUtilities() throws {
        let utilities = layout(.utilities)
        let frame = try #require(utilities.trayFrame(islandWidth: 800, topHeight: 38))
        let clipboard = try #require(utilities.clipboardFrame(islandWidth: 800, topHeight: 38))
        #expect(frame.minX >= clipboard.maxX && frame.minY == clipboard.minY)
        #expect(frame.height == IslandExpandedLayout.moduleHeight)
        #expect(TrayModuleLayout.slotCount(in: frame.size) >= TrayShelf.capacity)
        let item = TrayModuleLayout.itemFrame(5, in: frame.size)
        let point = CGPoint(x: frame.minX + item.midX, y: frame.minY + item.midY)
        let ids = (0..<12).map(String.init)
        #expect(utilities.trayControl(at: point, islandWidth: 800, topHeight: 38, ids: ids) == .item("5"))
        #expect(utilities.trayControl(at: CGPoint(x: 5, y: 5), islandWidth: 800, topHeight: 38, ids: ids) == nil)
        for other in [IslandTab.desktops, .developer] {
            #expect(layout(other).trayFrame(islandWidth: 800, topHeight: 38) == nil, "\(other)")
            #expect(layout(other).trayControl(at: point, islandWidth: 800, topHeight: 38, ids: ids) == nil, "\(other)")
        }
    }

    // Arrastrar un archivo hacia la isla abre Utilidades, donde está la bandeja, sea cual sea la última pestaña
    @Test func draggingAFileOpensUtilities() {
        for last in IslandTab.allCases {
            #expect(IslandTab.opening(.drop, last: last, among: IslandTab.allCases) == .utilities)
        }
        #expect(!IslandTab.Opening.drop.usesVimKeys)
        // Sin la pestaña entre las visibles, los escritorios
        #expect(IslandTab.opening(.drop, last: .developer, among: [.desktops, .developer]) == .desktops)
    }

    @Test func removeIsTheOnlyControlThatRemoves() {
        #expect(TrayControl.remove("a").isRemove && !TrayControl.item("a").isRemove)
    }
}

// MARK: - El almacén, con archivos de verdad

/// Retiene una tarea hasta que se abre, para probar lo que llega tarde
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

@MainActor
struct TrayStoreTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "tray-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ name: String, in directory: URL? = nil, text: String = "hola") throws -> URL {
        let target = (directory ?? folder).appending(path: name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        // Las rutas de /var y /private/var son la misma: la bandeja guarda la estándar
        return URL(fileURLWithPath: target.path)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "tray-tests-\(UUID().uuidString)")!
    }

    private func waitForCheck(_ store: TrayStore, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(condition() ? 0 : 5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aDroppedFileIsKeptByReferenceWithABookmark() async throws {
        let store = TrayStore(defaults: defaults())
        let url = try file("informe.txt")
        #expect(store.add(urls: [url]) == 1)
        let item = try #require(store.shelf.items.first)
        #expect(item.path == url.standardizedFileURL.path && item.name == "informe.txt")
        // El marcador no se crea al soltar (en el hilo principal) sino en la comprobación, fuera de él
        #expect(item.bookmark == nil)
        try await waitForCheck(store) { store.shelf.items.first?.bookmark != nil }
        #expect(store.shelf.items.first?.bookmark != nil && store.verified == [item.id])
        // No se copió nada: el archivo sigue donde estaba y la carpeta no tiene más
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["informe.txt"])
    }

    @Test func whatIsNotALocalFileIsIgnored() throws {
        let store = TrayStore(defaults: defaults())
        #expect(store.add(urls: [try #require(URL(string: "https://example.com/a.pdf"))]) == 0)
        #expect(store.isEmpty)
    }

    @Test func theListSurvivesARestart() async throws {
        let suite = defaults()
        let first = TrayStore(defaults: suite)
        first.add(urls: [try file("uno.txt"), try file("dos.txt")])
        try await waitForCheck(first) { first.shelf.items.allSatisfy { $0.bookmark != nil } }
        let reloaded = TrayStore(defaults: suite)
        #expect(reloaded.shelf.items.map(\.name) == ["uno.txt", "dos.txt"])
        #expect(reloaded.shelf.items.allSatisfy { $0.bookmark != nil })
        // Quitarlos todos borra lo guardado
        for item in reloaded.shelf.items { reloaded.remove(id: item.id) }
        #expect(TrayStore(defaults: suite).isEmpty && suite.data(forKey: TrayStore.defaultsKey) == nil)
    }

    @Test func aDeletedFileIsMarkedMissingAndCannotBeDragged() async throws {
        let store = TrayStore(defaults: defaults())
        let keep = try file("queda.txt")
        let gone = try file("se-va.txt")
        store.add(urls: [keep, gone])
        try await waitForCheck(store) { store.verified.count == 2 }
        #expect(store.missing.isEmpty && store.verified.count == 2)
        let goneID = try #require(store.shelf.items.first { $0.name == "se-va.txt" }?.id)
        let keepID = try #require(store.shelf.items.first { $0.name == "queda.txt" }?.id)
        #expect(store.url(for: goneID) != nil)
        try FileManager.default.removeItem(at: gone)
        store.refresh()
        try await waitForCheck(store) { store.missing == [goneID] }
        #expect(store.missing == [goneID] && store.verified == [keepID])
        #expect(store.url(for: goneID) == nil && store.url(for: keepID) != nil)
        // La lista no pierde el elemento: se marca, y se quita con la «×»
        #expect(store.shelf.items.count == 2)
        store.remove(id: goneID)
        #expect(store.shelf.items.count == 1 && store.missing.isEmpty)
    }

    // El marcador sigue al archivo: renombrado o movido, el elemento no falta
    @Test func aRenamedFileIsFollowedByItsBookmark() async throws {
        let suite = defaults()
        let store = TrayStore(defaults: suite)
        let original = try file("antes.txt", text: "contenido")
        store.add(urls: [original])
        let id = try #require(store.shelf.items.first?.id)
        // Sin marcador no se puede seguir a un renombrado: primero la comprobación que lo crea
        try await waitForCheck(store) { store.shelf.items.first?.bookmark != nil }
        let renamed = folder.appending(path: "despues.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        store.refresh()
        try await waitForCheck(store) { store.shelf.items.first?.name == "despues.txt" }
        #expect(store.shelf.items.first?.name == "despues.txt" && store.shelf.items.first?.id == id)
        #expect(store.missing.isEmpty)
        // Y lo nuevo queda guardado
        #expect(TrayStore(defaults: suite).shelf.items.first?.name == "despues.txt")
        #expect(store.url(for: id)?.lastPathComponent == "despues.txt")
    }

    @Test func aFileInTheTrashCountsAsMissing() throws {
        let inTrash = try file("tirado.txt", in: folder.appending(path: ".Trash"))
        let item = TrayItem(path: inTrash.path, bookmark: nil, added: now)
        let outside = TrayItem(path: try file("fuera.txt").path, bookmark: nil, added: now)
        let results = TrayStore.resolve([item, outside])
        #expect(results[0].path == nil && results[1].path != nil)
    }

    @Test func aFileWithoutBookmarkIsCheckedByItsPath() throws {
        let present = TrayItem(path: try file("presente.txt").path, bookmark: nil, added: now)
        let absent = TrayItem(path: folder.appending(path: "ausente.txt").path, bookmark: nil, added: now)
        let results = TrayStore.resolve([present, absent])
        #expect(results[0].path == present.path && results[1].path == nil)
    }

    @Test func garbageInDefaultsIsAnEmptyTray() throws {
        let suite = defaults()
        suite.set(Data("esto no es json".utf8), forKey: TrayStore.defaultsKey)
        #expect(TrayStore(defaults: suite).isEmpty)
        suite.set(Data(repeating: 0x20, count: TrayStore.maxStoredBytes + 1), forKey: TrayStore.defaultsKey)
        #expect(TrayStore(defaults: suite).isEmpty)
    }

    // Una comprobación lenta (un volumen de red) que llega cuando la lista ya cambió no pisa lo nuevo: la primera se retiene a propósito
    @Test func aStaleCheckDoesNotOverwriteTheNewerList() async throws {
        let gate = Gate()
        let calls = Counter()
        let store = TrayStore(defaults: defaults(), resolver: { items in
            let call = await calls.next()
            // La primera dice que todo falta, pero tarda; la segunda es la buena
            if call == 1 {
                await gate.wait()
                return items.map { TrayResolution(id: $0.id, path: nil, bookmark: nil) }
            }
            return items.map { TrayResolution(id: $0.id, path: $0.path, bookmark: nil) }
        })
        store.add(urls: [try file("uno.txt")])
        // Da tiempo a que la primera comprobación quede retenida en la puerta
        try await Task.sleep(for: .milliseconds(200))
        let firstID = try #require(store.shelf.items.first?.id)
        store.add(urls: [try file("dos.txt")])
        try await waitForCheck(store) { store.verified.count == 2 }
        #expect(store.missing.isEmpty && store.verified.count == 2)
        // Ahora llega la primera, tardía: no marca nada como que falta
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.missing.isEmpty && store.verified.contains(firstID))
    }

    // La Papelera no se ofrece ni antes de la primera comprobación
    @Test func aFileInTheTrashIsNeverOffered() throws {
        let store = TrayStore(defaults: defaults())
        let trashed = try file("tirado.txt", in: folder.appending(path: ".Trash"))
        store.add(urls: [trashed])
        let id = try #require(store.shelf.items.first?.id)
        #expect(store.url(for: id) == nil)
        #expect(TrayStore.isTrashed(trashed) && !TrayStore.isTrashed(folder.appending(path: "normal.txt")))
        #expect(TrayStore.isTrashed(URL(fileURLWithPath: "/Volumes/Disco/.Trashes/501/x")))
    }
}

// MARK: - Lo que se arrastra sobre la isla

/// Un arrastre simulado: lleva su portapapeles propio (nunca el general) y la fuente que se diga
@MainActor
private final class FakeDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?

    init(pasteboard: NSPasteboard, source: Any? = nil) {
        draggingPasteboard = pasteboard
        draggingSource = source
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@MainActor
struct TrayDropTests {
    private final class Log {
        var overCount = 0
        var leftCount = 0
        var dropped: [[URL]] = []
        var accepts = true
    }

    private func pasteboard(files: [URL] = [], text: String? = nil) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("tray-test-\(UUID().uuidString)"))
        board.clearContents()
        if !files.isEmpty { board.writeObjects(files as [NSURL]) }
        if let text { board.setString(text, forType: .string) }
        return board
    }

    private func handlers(_ log: Log) -> FileDropHandlers {
        FileDropHandlers(
            over: { log.overCount += 1; return log.accepts },
            left: { log.leftCount += 1 },
            dropped: { log.dropped.append($0); return true }
        )
    }

    @Test func aFileDragIsAcceptedAsACopy() {
        let log = Log()
        let info = FakeDraggingInfo(pasteboard: pasteboard(files: [URL(fileURLWithPath: "/tmp/x.txt")]))
        #expect(handlers(log).operation(for: info) == .copy && log.overCount == 1)
        // La isla puede decir que no (por ejemplo mientras cambia el escritorio)
        log.accepts = false
        #expect(handlers(log).operation(for: info).isEmpty)
    }

    @Test func whatIsNotAFileIsIgnored() {
        let log = Log()
        let text = FakeDraggingInfo(pasteboard: pasteboard(text: "solo texto"))
        #expect(handlers(log).operation(for: text).isEmpty && log.overCount == 0)
        #expect(handlers(log).perform(text) == false && log.dropped.isEmpty)
        // Una dirección web no es un archivo local
        let board = NSPasteboard(name: NSPasteboard.Name("tray-test-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([URL(string: "https://example.com/a.pdf")! as NSURL])
        let web = FakeDraggingInfo(pasteboard: board)
        #expect(handlers(log).operation(for: web).isEmpty && log.overCount == 0)
    }

    // Lo que arrastra la propia isla no se acepta de vuelta: no se duplica
    @Test func itsOwnDragIsNotAcceptedBack() {
        let log = Log()
        let info = FakeDraggingInfo(
            pasteboard: pasteboard(files: [URL(fileURLWithPath: "/tmp/x.txt")]), source: TrayDragSource()
        )
        #expect(handlers(log).operation(for: info).isEmpty && log.overCount == 0)
        #expect(handlers(log).perform(info) == false && log.dropped.isEmpty)
    }

    @Test func droppingHandsOverEveryFile() {
        let log = Log()
        let files = [URL(fileURLWithPath: "/tmp/uno.txt"), URL(fileURLWithPath: "/tmp/dos.txt")]
        let info = FakeDraggingInfo(pasteboard: pasteboard(files: files))
        #expect(handlers(log).perform(info) == true)
        #expect(log.dropped.first?.map(\.lastPathComponent) == ["uno.txt", "dos.txt"])
    }

    // El contenedor es el destino: registrado para archivos y con los mismos manejadores
    @Test func theContainerIsTheRegisteredDestination() {
        let container = IslandContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(container.registeredDraggedTypes.contains(.fileURL))
        let log = Log()
        container.dropHandlers = handlers(log)
        let info = FakeDraggingInfo(pasteboard: pasteboard(files: [URL(fileURLWithPath: "/tmp/x.txt")]))
        #expect(container.draggingEntered(info) == .copy && container.draggingUpdated(info) == .copy)
        #expect(container.performDragOperation(info))
        container.draggingExited(info)
        container.draggingEnded(info)
        #expect(log.overCount == 2 && log.leftCount == 2 && log.dropped.count == 1)
        // Sin manejadores no acepta nada
        let bare = IslandContainerView(frame: .zero)
        #expect(bare.draggingEntered(info).isEmpty && !bare.performDragOperation(info))
    }

    // Lo que se arrastra hacia fuera es siempre una copia: ni mover ni borrar el original (el Finder en el mismo volumen, la papelera del Dock)
    @Test func whatLeavesTheIslandIsOnlyEverACopy() {
        let offered = TrayDragSource.operation
        #expect(offered == .copy)
        #expect(!offered.contains(.move) && !offered.contains(.delete) && !offered.contains(.generic) && !offered.contains(.link))
    }
}
