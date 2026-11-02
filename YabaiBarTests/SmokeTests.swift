import Foundation
import Testing
@testable import YabaiBar

// Comprueba que el target de tests compila y enlaza con la app; se reemplaza en la fase 2
@Test func appModuleLoads() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
