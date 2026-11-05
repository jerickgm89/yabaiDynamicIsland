import Testing
@testable import YabaiBar

struct MacModelsTests {
    // Los identificadores de las páginas de soporte de Apple (comprobadas el 2026-11-04)
    private let notched = [
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,9", "Mac14,6", "Mac14,10",
        "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,10", "Mac15,7", "Mac15,9", "Mac15,11",
        "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,5", "Mac16,7",
        "Mac17,2", "Mac17,7", "Mac17,9", "Mac17,6", "Mac17,8",
        "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13", "Mac17,3", "Mac17,4",
    ]

    @Test func everyNotchedMacBookFromM1ProToM5IsNamed() {
        for identifier in notched {
            let model = MacModels.model(for: identifier)
            #expect(model?.hasNotch == true, "\(identifier)")
            #expect(model?.name.hasPrefix("MacBook ") == true, "\(identifier)")
        }
        #expect(MacModels.catalog.values.filter(\.hasNotch).count == notched.count)
    }

    @Test func namesSayTheSizeChipAndYear() {
        #expect(MacModels.model(for: "MacBookPro18,1")?.name == "MacBook Pro de 16\" con M1 Pro (2021)")
        #expect(MacModels.model(for: "Mac15,13")?.name == "MacBook Air de 15\" con M3 (2024)")
        #expect(MacModels.model(for: "Mac17,8")?.name == "MacBook Pro de 16\" con M5 Pro o M5 Max (2026)")
    }

    // El Air M1, el Pro de 13" con M1 y el de 13" con M2 (Touch Bar) no tienen notch
    @Test func laptopsWithoutNotch() {
        for identifier in ["MacBookAir10,1", "MacBookPro17,1", "Mac14,7"] {
            #expect(MacModels.model(for: identifier)?.hasNotch == false, "\(identifier)")
        }
    }

    // Los Mac de escritorio y los modelos que aún no conoce el catálogo
    @Test func unknownModelsAreNil() {
        for identifier in ["Mac14,13", "Mac13,1", "Mac18,3", ""] {
            #expect(MacModels.model(for: identifier) == nil, "\(identifier)")
        }
    }

    @Test func readsThisMacModel() {
        #expect(!MacModels.current.isEmpty)
    }
}
