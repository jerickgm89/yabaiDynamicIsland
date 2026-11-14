import AppKit
import Foundation
import Observation
import os
import UniformTypeIdentifiers

// El módulo Bandeja de la pestaña Utilidades: lo que se suelta en la isla, para volver a sacarlo hacia otra app.
//
// Guarda referencias (ruta y marcador), nunca copias ni contenido, y no abre ni ejecuta nada de lo que hay en ella: lo único que hace
// con un archivo es mostrarlo en el Finder si lo pulsas, o entregarlo (como copia) a la app donde lo sueltes. El disco se mira fuera
// del hilo principal, solo al soltar y al ver la pestaña (no hay temporizador). Ni las rutas ni los nombres van a ningún log.

/// Lo que guarda la bandeja en `UserDefaults`: la lista, como JSON. Los tests usan su propio dominio
@MainActor
@Observable
final class TrayStore {
    static let defaultsKey = "trayItems"
    /// Más de esto en `UserDefaults` no es nuestro: 12 marcadores no llegan a 20 KB
    static let maxStoredBytes = 1_000_000

    private(set) var shelf = TrayShelf()
    /// Los que ya no están en el disco (borrados, o en la Papelera), según la última comprobación
    private(set) var missing: Set<String> = []
    /// Los que esa comprobación encontró: solo a esos se les pide el ícono real
    private(set) var verified: Set<String> = []

    /// Dónde está cada archivo ahora. En los tests se cambia por una que se pueda retener
    typealias Resolver = @Sendable ([TrayItem]) async -> [TrayResolution]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let resolver: Resolver
    /// Sube con cada cambio de la lista y cada comprobación: lo que llega tarde de un disco lento no se publica
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    init(defaults: UserDefaults, clock: @escaping () -> Date = { Date() }, resolver: @escaping Resolver = { TrayStore.resolve($0) }) {
        self.defaults = defaults
        self.clock = clock
        self.resolver = resolver
        shelf = Self.load(from: defaults)
    }

    var snapshot: TraySnapshot {
        #if DEBUG
        if let demo { return demo }
        #endif
        return .make(shelf: shelf, missing: missing, verified: verified)
    }

    var isEmpty: Bool { shelf.items.isEmpty }

    // MARK: - Lo guardado

    private static func load(from defaults: UserDefaults) -> TrayShelf {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= maxStoredBytes else { return TrayShelf() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return TrayShelf(items: (try? decoder.decode([TrayItem].self, from: data)) ?? [])
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if shelf.items.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? encoder.encode(shelf.items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Lo que se suelta y se quita

    /// Apunta lo que se soltó: solo archivos locales, de los que se saca la ruta. El marcador lo crea la comprobación del disco, fuera
    /// del hilo principal: soltar 3000 archivos (o uno de un volumen lento) no congela la isla. Devuelve cuántos se apuntaron
    @discardableResult
    func add(urls: [URL]) -> Int {
        let drops = urls.compactMap { url in TrayShelf.path(of: url).map { TrayDrop(path: $0, bookmark: nil) } }
        let added = shelf.add(drops, at: clock())
        guard added > 0 else { return 0 }
        save()
        Logger.tools.info("Bandeja: \(added, privacy: .public) archivos soltados, \(self.shelf.items.count, privacy: .public) en total")
        refresh()
        return added
    }

    func remove(id: String) {
        guard shelf.items.contains(where: { $0.id == id }) else { return }
        shelf.remove(id: id)
        missing.remove(id)
        verified.remove(id)
        save()
        refresh()
    }

    // MARK: - El disco

    /// Mira dónde está ahora cada archivo (con su marcador, que sigue a los que se renombran o se mueven) y cuáles ya no existen. Fuera
    /// del hilo principal: un volumen de red que no contesta no congela la isla
    func refresh() {
        generation += 1
        let current = generation
        checkTask?.cancel()
        let items = shelf.items
        guard !items.isEmpty else {
            missing = []
            verified = []
            return
        }
        let resolver = resolver
        checkTask = Task { [weak self] in
            let resolutions = await Task.detached(priority: .utility) { await resolver(items) }.value
            guard !Task.isCancelled, let self, generation == current else { return }
            let before = shelf
            shelf.apply(resolutions)
            missing = TrayShelf.missing(resolutions)
            verified = Set(resolutions.filter { $0.path != nil }.map(\.id))
            if shelf != before { save() }
        }
    }

    /// Donde está cada archivo ahora. Sin interfaz ni montar volúmenes: lo que no responde cuenta como que falta. A los que todavía no
    /// tienen marcador (los recién soltados) se les crea aquí, fuera del hilo principal
    nonisolated static func resolve(_ items: [TrayItem]) -> [TrayResolution] {
        items.map { item in
            var url: URL?
            var renewed: Data?
            if let bookmark = item.bookmark {
                var stale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale
                ) {
                    url = resolved
                    if stale { renewed = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
                }
            }
            if url == nil { url = URL(fileURLWithPath: item.path) }
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                return TrayResolution(id: item.id, path: nil, bookmark: nil)
            }
            // Lo que se tiró a la Papelera sigue existiendo, pero para la bandeja ya no está
            if isTrashed(url) { return TrayResolution(id: item.id, path: nil, bookmark: nil) }
            if item.bookmark == nil, renewed == nil {
                renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return TrayResolution(id: item.id, path: url.standardizedFileURL.path, bookmark: renewed)
        }
    }

    /// En la Papelera (la del usuario o la de un volumen): existe, pero para la bandeja ya no está
    nonisolated static func isTrashed(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    // MARK: - Lo que se hace con un elemento

    /// El archivo de un elemento, si sigue existiendo: lo que se muestra en el Finder o se arrastra. nil si falta
    func url(for id: String) -> URL? {
        guard !missing.contains(id), let item = shelf.items.first(where: { $0.id == id }) else { return nil }
        let url = URL(fileURLWithPath: item.path)
        // Un archivo en la Papelera existe, pero no se ofrece (ni antes de la primera comprobación)
        guard !Self.isTrashed(url), FileManager.default.fileExists(atPath: item.path) else { return nil }
        return url
    }

    #if DEBUG
    /// Lo que había antes de la demo, para devolverlo
    private var demo: TraySnapshot?

    /// Para el snapshot de la isla: archivos inventados (no existen), sin tocar lo guardado
    func injectDemo(count: Int = 7) {
        let names = [
            "informe-q3.pdf", "captura.png", "presupuesto.xlsx", "yabai-notas.md", "build.zip", "logo.svg", "Proyecto",
            "contrato.docx", "demo.mov", "datos.csv", "script.sh", "viejo.txt",
        ]
        demo = TraySnapshot(items: names.prefix(count).enumerated().map { index, name in
            TraySnapshot.Item(id: "demo-\(index)", name: name, path: "/demo/\(name)", isMissing: index == 5, isVerified: true)
        })
    }

    func resetInjected() {
        demo = nil
    }

    /// Lo que se dibuja en el snapshot: tus archivos de verdad no se guardan en una imagen (queda en la caché); solo lo inventado
    var snapshotForImage: TraySnapshot {
        if demo != nil { return snapshot }
        return TraySnapshot(items: snapshot.items.map {
            TraySnapshot.Item(id: $0.id, name: "•••••", path: "", isMissing: $0.isMissing, isVerified: false)
        })
    }
    #endif
}

/// Los íconos de los archivos de la bandeja. Un archivo que existe pide el suyo (una app, una carpeta o una miniatura tienen el suyo); uno
/// que falta usa el de su tipo por la extensión, sin tocar el disco. Se guardan: pedirlos en cada dibujo sería caro
@MainActor
final class TrayIcons {
    private var cache: [String: NSImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .data)
    /// Los archivos inventados de la demo de DEBUG no existen: se les da el ícono de su tipo, como a los que faltan
    static let demoPrefix = "/demo/"

    /// El ícono real solo se pide a lo que la comprobación del disco encontró (`isVerified`): hasta entonces, el de su tipo, sin tocar el
    /// disco. Así un volumen colgado no congela el dibujo al abrir la pestaña
    func icon(path: String, isMissing: Bool, isVerified: Bool) -> NSImage {
        let byType = isMissing || !isVerified || path.hasPrefix(Self.demoPrefix)
        let key = (byType ? "t:" : "f:") + path
        if let cached = cache[key] { return cached }
        let icon: NSImage
        if path.isEmpty {
            icon = Self.generic
        } else if byType {
            let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(forFile: path)
        }
        // La caché no crece sin fin: 12 archivos en la bandeja, y se vacía al pasar de 64 entradas
        if cache.count > 64 { cache = [:] }
        cache[key] = icon
        return icon
    }
}
