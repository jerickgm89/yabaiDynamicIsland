import Foundation

// Catálogo de los portátiles con Apple silicon: el nombre de cada identificador (`hw.model`) y si su pantalla tiene
// notch. Es puro salvo `current`, que lee el modelo de este Mac una sola vez. Solo sirve para nombrar el Mac en «Primeros pasos» y en los datos de la pantalla. La isla siempre
// mide el notch en la pantalla (NotchGeometry): en puntos cambia con la escala que elija el usuario, así que una
// tabla de medidas por modelo no valdría. Identificadores de las páginas de soporte de Apple «Identificar el modelo
// de MacBook Pro» (108052) y «de MacBook Air» (102869), comprobadas el 2026-11-04. Donde Apple agrupa varios
// identificadores sin decir cuál es cuál, el nombre lleva los dos chips.
enum MacModels {
    struct Model: Equatable, Sendable {
        let name: String
        let hasNotch: Bool
    }

    static func model(for identifier: String) -> Model? {
        catalog[identifier]
    }

    /// `hw.model` de este Mac, por ejemplo "MacBookPro18,1"; vacío si no se puede leer
    static let current: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }()

    static let catalog: [String: Model] = {
        var catalog: [String: Model] = [:]
        func add(_ identifiers: [String], _ name: String, notch: Bool = true) {
            for identifier in identifiers { catalog[identifier] = Model(name: name, hasNotch: notch) }
        }
        // MacBook Pro
        add(["MacBookPro18,1"], "MacBook Pro de 16\" con M1 Pro (2021)")
        add(["MacBookPro18,2"], "MacBook Pro de 16\" con M1 Max (2021)")
        add(["MacBookPro18,3"], "MacBook Pro de 14\" con M1 Pro (2021)")
        add(["MacBookPro18,4"], "MacBook Pro de 14\" con M1 Max (2021)")
        add(["Mac14,5", "Mac14,9"], "MacBook Pro de 14\" con M2 Pro o M2 Max (2023)")
        add(["Mac14,6", "Mac14,10"], "MacBook Pro de 16\" con M2 Pro o M2 Max (2023)")
        add(["Mac15,3"], "MacBook Pro de 14\" con M3 (2023)")
        add(["Mac15,6", "Mac15,8", "Mac15,10"], "MacBook Pro de 14\" con M3 Pro o M3 Max (2023)")
        add(["Mac15,7", "Mac15,9", "Mac15,11"], "MacBook Pro de 16\" con M3 Pro o M3 Max (2023)")
        add(["Mac16,1"], "MacBook Pro de 14\" con M4 (2024)")
        add(["Mac16,6", "Mac16,8"], "MacBook Pro de 14\" con M4 Pro o M4 Max (2024)")
        add(["Mac16,5", "Mac16,7"], "MacBook Pro de 16\" con M4 Pro o M4 Max (2024)")
        add(["Mac17,2"], "MacBook Pro de 14\" con M5 (2025)")
        add(["Mac17,7", "Mac17,9"], "MacBook Pro de 14\" con M5 Pro o M5 Max (2026)")
        add(["Mac17,6", "Mac17,8"], "MacBook Pro de 16\" con M5 Pro o M5 Max (2026)")
        // MacBook Air
        add(["Mac14,2"], "MacBook Air de 13\" con M2 (2022)")
        add(["Mac14,15"], "MacBook Air de 15\" con M2 (2023)")
        add(["Mac15,12"], "MacBook Air de 13\" con M3 (2024)")
        add(["Mac15,13"], "MacBook Air de 15\" con M3 (2024)")
        add(["Mac16,12"], "MacBook Air de 13\" con M4 (2025)")
        add(["Mac16,13"], "MacBook Air de 15\" con M4 (2025)")
        add(["Mac17,3"], "MacBook Air de 13\" con M5 (2026)")
        add(["Mac17,4"], "MacBook Air de 15\" con M5 (2026)")
        // Sin notch
        add(["MacBookAir10,1"], "MacBook Air con M1 (2020)", notch: false)
        add(["MacBookPro17,1"], "MacBook Pro de 13\" con M1 (2020)", notch: false)
        add(["Mac14,7"], "MacBook Pro de 13\" con M2 (2022)", notch: false)
        return catalog
    }()
}
