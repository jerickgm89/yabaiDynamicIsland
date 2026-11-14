import CoreGraphics
import Foundation
import Testing
@testable import YabaiBar

// El módulo Portapapeles de Utilidades (fase 43): las herramientas, el historial y sus filtros, los colores, dónde está cada cosa y el
// almacén, con un portapapeles y un cuentagotas falsos (nunca se toca el portapapeles del usuario ni se pregunta nada a macOS).

struct DevToolboxTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func run(_ tool: DevTool, _ input: String?, zone: TimeZone? = nil) -> Result<DevToolResult, DevToolFailure> {
        DevToolbox.run(tool, input: input, timeZone: zone ?? utc, makeUUID: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! })
    }

    private func text(_ tool: DevTool, _ input: String?) throws -> String {
        try run(tool, input).get().text
    }

    private func failure(_ tool: DevTool, _ input: String?) -> DevToolFailure? {
        if case .failure(let failure) = run(tool, input) { failure } else { nil }
    }

    // MARK: JSON

    @Test func jsonIsFormattedWithSortedKeys() throws {
        let result = try run(.jsonFormat, #"{"b":1,"a":[1,2],"url":"https://x.dev/a"}"#).get()
        #expect(result.text == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1,\n  \"url\" : \"https://x.dev/a\"\n}")
        #expect(result.message == "JSON formateado")
    }

    @Test func jsonIsCompacted() throws {
        let result = try run(.jsonCompact, "{\n  \"b\" : 1,\n  \"a\" : [ 1, 2 ]\n}\n").get()
        #expect(result.text == #"{"a":[1,2],"b":1}"#)
        #expect(result.message == "JSON compactado")
    }

    @Test func jsonAcceptsAScalarAndIgnoresTheSurroundingSpaces() throws {
        #expect(try text(.jsonCompact, "  42  ") == "42")
        #expect(try text(.jsonFormat, "\"hola\"") == "\"hola\"")
        #expect(try text(.jsonCompact, "null") == "null")
    }

    @Test(arguments: ["{a:1}", "{'a':1}", "no es json", "{", "[1,2"])
    func notJSONSaysSo(input: String) {
        #expect(failure(.jsonFormat, input) == .invalid("No es JSON válido"))
        #expect(failure(.jsonCompact, input) == .invalid("No es JSON válido"))
    }

    // MARK: Base64

    @Test func base64EncodesAndDecodes() throws {
        #expect(try text(.base64Encode, "hola") == "aG9sYQ==")
        #expect(try text(.base64Decode, "aG9sYQ==") == "hola")
        #expect(try text(.base64Encode, "✓ à la moda") == "4pyTIMOgIGxhIG1vZGE=")
        #expect(try text(.base64Decode, "4pyTIMOgIGxhIG1vZGE=") == "✓ à la moda")
    }

    // Sin relleno, con saltos de línea y en la variante de las URL
    @Test func base64DecodesTheCommonVariants() throws {
        #expect(try text(.base64Decode, "aG9sYQ") == "hola")
        #expect(try text(.base64Decode, "aG9s\nYQ==\n") == "hola")
        #expect(try text(.base64Decode, "Pz8_Pj4-") == "???>>>")
    }

    @Test func base64SaysWhatIsWrong() {
        #expect(failure(.base64Decode, "esto no es base64!") == .invalid("No es base64"))
        // Son bytes, no texto
        #expect(failure(.base64Decode, "//4=") == .invalid("El resultado no es texto"))
    }

    // MARK: URL

    @Test func urlEncodesAComponentAndDecodesIt() throws {
        #expect(try text(.urlEncode, "a b&c=d/é") == "a%20b%26c%3Dd%2F%C3%A9")
        #expect(try text(.urlEncode, "libre-._~") == "libre-._~")
        #expect(try text(.urlDecode, "a%20b%26c%3Dd%2F%C3%A9") == "a b&c=d/é")
        #expect(failure(.urlDecode, "100%zz") == .invalid("URL mal codificada"))
    }

    // MARK: JWT

    /// Un JWT con la cabecera y el contenido dados y una firma cualquiera
    private func token(header: String, payload: String) -> String {
        func part(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(header)).\(part(payload)).firma-que-no-se-verifica"
    }

    @Test func aJWTIsReadWithoutVerifyingIt() throws {
        let jwt = token(header: #"{"alg":"HS256","typ":"JWT"}"#, payload: #"{"sub":"1234567890","name":"Ana","iat":1516239022,"exp":1516242622}"#)
        let result = try run(.jwt, jwt).get()
        #expect(result.text.hasPrefix("// cabecera\n{"))
        #expect(result.text.contains("\"alg\" : \"HS256\"") && result.text.contains("\"name\" : \"Ana\""))
        #expect(result.text.contains("emitido: 2018-01-18T01:30:22Z") && result.text.contains("caduca: 2018-01-18T02:30:22Z"))
        #expect(result.message == "JWT leído (sin verificar)")
        // El contenido va tras la cabecera
        let header = try #require(result.text.range(of: "// cabecera"))
        let body = try #require(result.text.range(of: "// contenido"))
        #expect(header.lowerBound < body.lowerBound)
    }

    @Test func aJWTWithoutSignatureStillReads() throws {
        let unsecured = String(token(header: #"{"alg":"none"}"#, payload: #"{"a":1}"#).split(separator: ".").prefix(2).joined(separator: "."))
        #expect(try text(.jwt, unsecured).contains("\"a\" : 1"))
    }

    @Test(arguments: ["abc.def.ghi", "solo texto", "a.b.c.d", "[1].[2].x", ".."])
    func notAJWTSaysSo(input: String) {
        #expect(failure(.jwt, input) == .invalid("No es un JWT"))
    }

    // MARK: UUID, SHA-256

    @Test func aNewUUIDNeedsNoInput() throws {
        let result = try run(.uuid, nil).get()
        #expect(result.text == "11111111-2222-3333-4444-555555555555" && result.message == "UUID nuevo copiado")
        #expect(!DevTool.uuid.needsInput && DevTool.sha256.needsInput)
        // Uno de verdad es distinto cada vez
        let first = try DevToolbox.run(.uuid, input: nil).get().text
        let second = try DevToolbox.run(.uuid, input: nil).get().text
        #expect(first != second && UUID(uuidString: first) != nil)
    }

    @Test func sha256IsTheOfficialDigestOfTheExactText() throws {
        #expect(try text(.sha256, "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // El texto tal cual, también con espacios y saltos de línea al final
        #expect(try text(.sha256, "abc\n") != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try text(.sha256, "abc").count == 64)
    }

    // MARK: Timestamp

    @Test func aTimestampBecomesADate() throws {
        let local = try run(.timestamp, "1700000000").get()
        #expect(local.text == "2023-11-14 22:13:20 (hora local)\n2023-11-14T22:13:20Z")
        // Milisegundos: lo detecta por el tamaño
        #expect(try text(.timestamp, "1700000000000") == local.text)
        // Con otro huso
        let bogota = try run(.timestamp, "1700000000", zone: TimeZone(identifier: "America/Bogota")).get()
        #expect(bogota.text == "2023-11-14 17:13:20 (hora local)\n2023-11-14T22:13:20Z")
        #expect(try text(.timestamp, "1700000000.5") == "2023-11-14 22:13:20 (hora local)\n2023-11-14T22:13:20.500Z")
        #expect(try text(.timestamp, "0") == "1970-01-01 00:00:00 (hora local)\n1970-01-01T00:00:00Z")
    }

    @Test func aDateBecomesATimestamp() throws {
        for input in ["2023-11-14T22:13:20Z", "2023-11-14 22:13:20", "2023-11-14T22:13:20", "2023-11-14T17:13:20-05:00"] {
            #expect(try text(.timestamp, input) == "1700000000\n1700000000000", "\(input)")
        }
        // Sin segundos
        #expect(try text(.timestamp, "2023-11-14 22:13") == "1699999980\n1699999980000")
        #expect(try text(.timestamp, "2023-11-14") == "1699920000\n1699920000000")
        #expect(try text(.timestamp, "2023-11-14T22:13:20.500Z") == "1700000000\n1700000000500")
    }

    @Test func notATimestampSaysSo() {
        #expect(failure(.timestamp, "mañana por la tarde") == .invalid("No es fecha ni timestamp"))
        #expect(failure(.timestamp, "99999999999999999") == .invalid("Timestamp demasiado grande"))
    }

    // Lo que alguien puede poner en el portapapeles a propósito: nada de esto cierra la app ni se queda sin respuesta
    @Test(arguments: ["[1e999]", "[-1e999]", #"{"a":1e999}"#, "1e999", "-1e999", "[1e-999]", "[NaN]", "[123456789012345678901234567890]"])
    func hostileNumbersNeverCrashTheJSONTools(input: String) {
        // Que devuelva algo, sea el resultado o el motivo: lo que importa es que sigue vivo (una excepción de Foundation lo cerraría)
        for tool in [DevTool.jsonFormat, .jsonCompact] {
            switch run(tool, input) {
            case .success(let result): #expect(!result.text.isEmpty, "\(input)")
            case .failure(let failure): #expect(!failure.message.isEmpty, "\(input)")
            }
        }
    }

    @Test func anInfiniteNumberIsRefusedWithAReason() {
        #expect(failure(.jsonFormat, "[1e999]") != nil && failure(.jsonCompact, #"{"a":-1e999}"#) != nil)
    }

    @Test func aVeryDeepJSONIsRefusedNotCrashed() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(failure(.jsonFormat, deep) != nil)
        #expect(failure(.jsonFormat, String(repeating: "[", count: 600)) != nil)
    }

    @Test func datesBeyondTheYear9999AreRefused() throws {
        for input in ["9999-12-31 23:59:59", "99999-01-01", "+275760-09-13T00:00:00Z"] {
            #expect(failure(.timestamp, input) != nil, "\(input)")
        }
        // Una fecha antigua, sí
        #expect(failure(.timestamp, "0001-01-01") == nil)
    }

    @Test func aJWTWithAbsurdDatesStillReadsWithoutConvertingThem() throws {
        for exp in ["1e300", "9999999999999999999", "-1e300", "253402300800"] {
            let jwt = token(header: #"{"alg":"none"}"#, payload: "{\"exp\":\(exp),\"a\":1}")
            let result = try run(.jwt, jwt).get()
            #expect(result.text.contains("\"a\" : 1") && !result.text.contains("caduca:"), "\(exp)")
        }
        // Un número que Foundation no sabe escribir tampoco lo cierra
        switch run(.jwt, token(header: #"{"alg":"none"}"#, payload: #"{"exp":1e999}"#)) {
        case .success(let result): #expect(!result.text.contains("caduca:"))
        case .failure(let failure): #expect(!failure.message.isEmpty)
        }
    }

    // MARK: Entradas que no sirven

    @Test func withoutTextNothingRuns() {
        for tool in DevTool.allCases where tool.needsInput {
            #expect(failure(tool, nil) == .noText, "\(tool)")
            #expect(failure(tool, "") == .noText && failure(tool, " \n\t ") == .noText, "\(tool)")
        }
        #expect(DevToolFailure.noText.message == "Portapapeles sin texto")
    }

    @Test func aHugeTextIsRefused() {
        let huge = String(repeating: "a", count: DevToolbox.maxInputBytes + 1)
        for tool in DevTool.allCases where tool.needsInput {
            #expect(failure(tool, huge) == .tooLarge, "\(tool)")
        }
    }

    @Test func everyToolHasALabelThatFitsItsButtonAndAUniqueTitle() {
        #expect(DevTool.allCases.count == 10)
        #expect(Set(DevTool.allCases.map(\.title)).count == 10 && Set(DevTool.allCases.map(\.label)).count == 10)
        #expect(DevTool.allCases.allSatisfy { $0.label.count <= 4 })
    }
}

struct ClipboardHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theNewestComesFirst() {
        var history = ClipboardHistory()
        let first = history.add("uno", at: now)
        let second = history.add("dos", at: now.addingTimeInterval(1))
        #expect(first && second)
        #expect(history.entries.map(\.text) == ["dos", "uno"])
    }

    @Test func aRepeatedCopyGoesToTheTopInsteadOfAppearingTwice() {
        var history = ClipboardHistory()
        for text in ["a", "b", "c"] { history.add(text, at: now) }
        history.add("a", at: now.addingTimeInterval(5))
        #expect(history.entries.map(\.text) == ["a", "c", "b"])
        #expect(history.entries.first?.date == now.addingTimeInterval(5))
    }

    @Test func onlyTwentyAreKeptAndSixShown() {
        var history = ClipboardHistory()
        for index in 0..<25 { history.add("copia \(index)", at: now) }
        #expect(history.entries.count == 20 && history.entries.first?.text == "copia 24" && history.entries.last?.text == "copia 5")
        #expect(history.visible.map(\.text) == (0..<6).map { "copia \(24 - $0)" })
        #expect(ClipboardHistory(entries: history.entries + history.entries).entries.count == 20)
    }

    @Test func emptyWhitespaceAndHugeTextsAreNotKept() {
        var history = ClipboardHistory()
        let empty = history.add("", at: now)
        let blank = history.add("  \n\t ", at: now)
        let huge = history.add(String(repeating: "x", count: ClipboardHistory.maxTextLength + 1), at: now)
        let limit = history.add(String(repeating: "x", count: ClipboardHistory.maxTextLength), at: now)
        #expect(!empty && !blank && !huge && limit)
        #expect(history.entries.count == 1)
    }

    // Lo que viene del disco pasa por las mismas reglas que una copia nueva
    @Test func entriesFromOutsideFollowTheSameRules() {
        let huge = String(repeating: "x", count: ClipboardHistory.maxTextLength + 1)
        let entries = [
            ClipboardEntry(id: "a", text: "uno", date: now), ClipboardEntry(id: "a", text: "dos", date: now),
            ClipboardEntry(id: "b", text: "uno", date: now), ClipboardEntry(id: "c", text: "  ", date: now),
            ClipboardEntry(id: "d", text: huge, date: now), ClipboardEntry(id: "e", text: "tres", date: now),
        ]
        let history = ClipboardHistory(entries: entries)
        #expect(history.entries.map(\.text) == ["uno", "dos", "tres"])
        // Los identificadores no se repiten (SwiftUI los usa para distinguir las filas)
        #expect(Set(history.entries.map(\.id)).count == 3)
    }

    @Test func aHugePreviewOnlyLooksAtTheStart() {
        let huge = String(repeating: "palabra ", count: 12_000)
        let preview = ClipboardHistory.preview(huge, limit: 26)
        #expect(preview.count == 26 && preview.hasSuffix("…"))
        // Un texto corto no lleva puntos suspensivos; uno solo de espacios al principio, tampoco se queda vacío
        #expect(ClipboardHistory.preview("hola", limit: 26) == "hola")
    }

    @Test func clearingEmptiesIt() {
        var history = ClipboardHistory()
        history.add("algo", at: now)
        history.clear()
        #expect(history.entries.isEmpty && history.visible.isEmpty)
    }

    @Test func aPreviewIsOneShortLine() {
        #expect(ClipboardHistory.preview("hola\n\n  mundo\t¿qué tal?") == "hola mundo ¿qué tal?")
        #expect(ClipboardHistory.preview("  espacios  ") == "espacios")
        let long = String(repeating: "abcde ", count: 30)
        let preview = ClipboardHistory.preview(long, limit: 20)
        #expect(preview.count == 20 && preview.hasSuffix("…"))
    }
}

struct ClipboardFilterTests {
    @Test func concealedAndTransientCopiesAreSkipped() {
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            #expect(ClipboardFilter.shouldSkip(types: ["public.utf8-plain-text", type], sourceBundleID: nil, ignoredApps: []), "\(type)")
        }
        #expect(!ClipboardFilter.shouldSkip(types: ["public.utf8-plain-text", "public.html"], sourceBundleID: "com.apple.Safari", ignoredApps: []))
        #expect(!ClipboardFilter.shouldSkip(types: [], sourceBundleID: nil, ignoredApps: []))
    }

    @Test func copiesFromTheListedAppsAreSkipped() {
        let ignored = Set(ClipboardFilter.defaultIgnoredApps)
        #expect(ClipboardFilter.shouldSkip(types: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password", ignoredApps: ignored))
        #expect(ClipboardFilter.shouldSkip(types: [], sourceBundleID: "com.bitwarden.desktop", ignoredApps: ignored))
        #expect(!ClipboardFilter.shouldSkip(types: [], sourceBundleID: "com.apple.Safari", ignoredApps: ignored))
        #expect(!ClipboardFilter.shouldSkip(types: [], sourceBundleID: nil, ignoredApps: ignored))
        #expect(ClipboardFilter.defaultIgnoredApps.allSatisfy(BundleIdentifier.isValid))
    }
}

struct ClipboardStateTests {
    @Test func theStateFollowsTheSettingAndWhatMacOSSays() {
        #expect(ClipboardHistoryState.make(enabled: false, behavior: .alwaysAllow) == .off)
        #expect(ClipboardHistoryState.make(enabled: false, behavior: .alwaysDeny) == .off)
        #expect(ClipboardHistoryState.make(enabled: true, behavior: .alwaysAllow) == .recording)
        #expect(ClipboardHistoryState.make(enabled: true, behavior: .unasked) == .needsFirstAccess)
        #expect(ClipboardHistoryState.make(enabled: true, behavior: .ask) == .needsAllow)
        #expect(ClipboardHistoryState.make(enabled: true, behavior: .alwaysDeny) == .denied)
    }
}

struct ClipboardColorTests {
    @Test func aColorIsWrittenInHex() {
        #expect(ColorHex.string(RGBColor(red: 0.1, green: 0.5, blue: 0.9)) == "#1A80E6")
        #expect(ColorHex.string(RGBColor(red: 0, green: 0, blue: 0)) == "#000000" && ColorHex.string(RGBColor(red: 1, green: 1, blue: 1)) == "#FFFFFF")
        // Fuera de rango se recorta
        #expect(ColorHex.string(RGBColor(red: 1.4, green: -0.2, blue: 0.5)) == "#FF0080")
    }

    @Test func hexIsReadBack() throws {
        let color = try #require(ColorHex.color("#1A80E6"))
        #expect(ColorHex.string(color) == "#1A80E6")
        #expect(ColorHex.color("1a80e6") != nil)
        for bad in ["", "#12345", "#1234567", "#GGGGGG", "azul", "#+1A2B3", "#-1A2B3", "#１２３４５６"] { #expect(ColorHex.color(bad) == nil, "\(bad)") }
        #expect(ColorHex.isValid("#ABCDEF") && !ColorHex.isValid("ABCDEF") && !ColorHex.isValid("#ABCDEG"))
    }

    @Test func theLastEightAreKeptWithoutRepeats() {
        var colors = ClipboardColors()
        for value in 0..<10 { colors.add(String(format: "#%02X0000", value * 10)) }
        #expect(colors.hexes.count == 8 && colors.hexes.first == "#5A0000" && colors.hexes.last == "#140000")
        colors.add("#140000")
        #expect(colors.hexes.first == "#140000" && colors.hexes.count == 8 && Set(colors.hexes).count == 8)
        colors.add("no es un color")
        colors.add("#ff00ff")
        #expect(colors.hexes.first == "#FF00FF" && colors.hexes.count == 8)
    }

    @Test func savedColorsAreValidated() {
        #expect(ClipboardColors(hexes: ["#abcdef", "nada", "#ABCDEF", "#123456"]).hexes == ["#ABCDEF", "#123456"])
        #expect(ClipboardColors(hexes: (0..<20).map { String(format: "#%02X0000", $0) }).hexes.count == 8)
    }
}

struct ClipboardLayoutTests {
    private let size = CGSize(width: 250, height: 112)

    private func control(
        _ point: CGPoint, mode: ClipboardMode = .history, state: ClipboardHistoryState = .recording, entries: Int = 6, swatches: Int = 8
    ) -> ClipboardControl? {
        ClipboardModuleLayout.control(at: point, in: size, mode: mode, state: state, entryCount: entries, swatchCount: swatches)
    }

    private func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    @Test func theHeaderButtonsSwitchTheModeAndClear() {
        #expect(control(center(ClipboardModuleLayout.toolsModeFrame(in: size))) == .mode(.tools))
        #expect(control(center(ClipboardModuleLayout.historyModeFrame(in: size)), mode: .tools) == .mode(.history))
        #expect(control(center(ClipboardModuleLayout.clearFrame(in: size))) == .clear)
        // Borrar solo existe con historial y con algo que borrar
        #expect(control(center(ClipboardModuleLayout.clearFrame(in: size)), entries: 0) == nil)
        #expect(control(center(ClipboardModuleLayout.clearFrame(in: size)), mode: .tools) == nil)
        #expect(control(center(ClipboardModuleLayout.clearFrame(in: size)), state: .off) == nil)
    }

    @Test func sixCopiesInTwoColumns() {
        for index in 0..<6 {
            let frame = ClipboardModuleLayout.entryFrame(index, in: size)
            #expect(control(center(frame)) == .entry(index))
            #expect(frame.maxX <= size.width - ClipboardModuleLayout.padding && frame.maxY <= size.height)
        }
        // Solo las que existen
        #expect(control(center(ClipboardModuleLayout.entryFrame(3, in: size)), entries: 3) == nil)
        #expect(control(center(ClipboardModuleLayout.entryFrame(2, in: size)), entries: 3) == .entry(2))
        let first = ClipboardModuleLayout.entryFrame(0, in: size)
        let second = ClipboardModuleLayout.entryFrame(1, in: size)
        #expect(first.maxX < second.minX && ClipboardModuleLayout.entryFrame(2, in: size).minY > first.maxY)
    }

    @Test func tenToolsAndTheColorRow() {
        for (index, tool) in DevTool.allCases.enumerated() {
            let frame = ClipboardModuleLayout.toolFrame(index, in: size)
            #expect(control(center(frame), mode: .tools) == .tool(tool))
            #expect(frame.maxX <= size.width - ClipboardModuleLayout.padding)
        }
        #expect(control(center(ClipboardModuleLayout.pickerFrame(in: size)), mode: .tools) == .picker)
        for index in 0..<8 {
            let frame = ClipboardModuleLayout.swatchFrame(index, in: size)
            #expect(control(center(frame), mode: .tools) == .swatch(index))
            #expect(frame.maxX <= size.width - ClipboardModuleLayout.padding && frame.maxY <= size.height)
        }
        #expect(control(center(ClipboardModuleLayout.swatchFrame(4, in: size)), mode: .tools, swatches: 4) == nil)
        // Las herramientas no responden en el modo historial, ni al revés
        #expect(control(center(ClipboardModuleLayout.toolFrame(0, in: size)), mode: .history, entries: 0) == nil)
    }

    @Test func withoutTheHistoryOnTheAccessButtonIsTheOnlyThing() {
        let button = center(ClipboardModuleLayout.accessFrame(in: size))
        for state in [ClipboardHistoryState.off, .needsFirstAccess, .needsAllow, .denied] {
            #expect(control(button, state: state, entries: 0) == .access, "\(state)")
            // Aunque hubiera copias de antes, no se ofrecen
            #expect(control(center(ClipboardModuleLayout.entryFrame(0, in: size)), state: state) == nil, "\(state)")
        }
        #expect(control(button, state: .recording, entries: 0) == nil)
        #expect(ClipboardModuleLayout.accessFrame(in: size).maxY <= size.height)
        // Las herramientas siguen funcionando sin historial
        #expect(control(center(ClipboardModuleLayout.toolFrame(0, in: size)), mode: .tools, state: .off) == .tool(.jsonFormat))
    }

    @Test func theIslandResolvesClipboardClicksOnlyInUtilities() throws {
        func layout(_ tab: IslandTab) -> IslandExpandedLayout {
            IslandExpandedLayout(
                spaces: [SpaceSummary(index: 1, isFocused: true, apps: [])], minBodyWidth: 396, maxBodyWidth: 1958, topHeight: 38, tab: tab,
                tabs: IslandTab.allCases, developerModules: ModuleID.modules(of: .developer), hasMedia: true, hasKeepAwake: true,
                hasPomodoro: true, hasSettingsButton: true
            )
        }
        let utilities = layout(.utilities)
        let frame = try #require(utilities.clipboardFrame(islandWidth: 800, topHeight: 38))
        #expect(frame.size == CGSize(width: 250, height: IslandExpandedLayout.moduleHeight))
        // Junto al calendario, no encima
        let calendar = try #require(utilities.calendarFrame(islandWidth: 800, topHeight: 38))
        #expect(frame.minX > calendar.maxX && frame.minY == calendar.minY)
        let entry = ClipboardModuleLayout.entryFrame(0, in: frame.size)
        let point = CGPoint(x: frame.minX + entry.midX, y: frame.minY + entry.midY)
        #expect(utilities.clipboardControl(at: point, islandWidth: 800, topHeight: 38, mode: .history, state: .recording, entryCount: 3, swatchCount: 0) == .entry(0))
        #expect(utilities.calendarControl(at: point, islandWidth: 800, topHeight: 38, access: .granted, joinable: []) == nil)
        #expect(utilities.clipboardControl(at: CGPoint(x: 5, y: 5), islandWidth: 800, topHeight: 38, mode: .history, state: .recording, entryCount: 3, swatchCount: 0) == nil)
        for other in [IslandTab.desktops, .developer] {
            #expect(layout(other).clipboardFrame(islandWidth: 800, topHeight: 38) == nil)
            #expect(layout(other).clipboardControl(at: point, islandWidth: 800, topHeight: 38, mode: .history, state: .recording, entryCount: 3, swatchCount: 0) == nil)
        }
    }
}

// MARK: - El almacén, con un portapapeles y un cuentagotas falsos

@MainActor
final class FakeClipboard: ClipboardSource {
    var changeCount = 1
    var accessBehavior: ClipboardAccessBehavior = .alwaysAllow
    var types: [String] = ["public.utf8-plain-text"]
    var frontmostBundleID: String?
    var text: String?
    /// macOS no deja leer: `string()` devuelve nil aunque haya texto
    var withholdsText = false
    /// Cuántas veces se leyó el texto: es lo que macOS puede preguntar al usuario
    private(set) var reads = 0
    private(set) var writes: [String] = []
    /// Cuáles de esas escrituras se marcaron como ocultas
    private(set) var concealedWrites: [Bool] = []
    /// Para simular una copia que llega justo mientras se lee
    var onRead: (() -> Void)?

    /// Lo que copia el usuario desde otra app
    func userCopies(_ text: String, types: [String]? = nil, from app: String? = nil) {
        self.text = text
        // Una copia nueva trae sus propios tipos: los de la anterior no se heredan
        self.types = types ?? ["public.utf8-plain-text"]
        frontmostBundleID = app
        changeCount += 1
    }

    func string() -> String? {
        reads += 1
        let read = withholdsText ? nil : text
        onRead?()
        return read
    }

    func write(_ text: String, concealed: Bool) {
        self.text = text
        writes.append(text)
        concealedWrites.append(concealed)
        types = concealed ? ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"] : ["public.utf8-plain-text"]
        changeCount += 1
    }
}

@MainActor
final class FakeColorPicker: ColorPicking {
    var next: RGBColor?
    private(set) var picks = 0

    func pick(_ completion: @escaping @MainActor (RGBColor?) -> Void) {
        picks += 1
        completion(next)
    }
}

@MainActor
struct ClipboardStoreTests {
    private func make(
        enabled: Bool = true, behavior: ClipboardAccessBehavior = .alwaysAllow, persist: Bool = false, url: URL? = nil
    ) -> (store: ClipboardStore, clipboard: FakeClipboard, picker: FakeColorPicker, settings: AppSettings) {
        let clipboard = FakeClipboard()
        clipboard.accessBehavior = behavior
        let picker = FakeColorPicker()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "clipboard-tests-\(UUID().uuidString)")!)
        settings.clipboardHistory = enabled
        settings.clipboardPersist = persist
        let file = url ?? FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        let store = ClipboardStore(source: clipboard, picker: picker, settings: settings, persistence: ClipboardPersistence(url: file))
        return (store, clipboard, picker, settings)
    }

    // MARK: Historial

    @Test func itRecordsWhatIsCopiedOnlyWhenItChanges() {
        let (store, clipboard, _, _) = make()
        store.poll()
        #expect(clipboard.reads == 0 && store.history.entries.isEmpty)
        clipboard.userCopies("primera")
        store.poll()
        store.poll()
        #expect(clipboard.reads == 1 && store.history.entries.map(\.text) == ["primera"])
        clipboard.userCopies("segunda")
        store.poll()
        #expect(store.history.entries.map(\.text) == ["segunda", "primera"] && clipboard.reads == 2)
    }

    // Lo que ya había al arrancar no se lee: el texto solo se lee si cambió desde que se empezó a mirar
    @Test func whatWasThereBeforeIsNeverRead() {
        let clipboard = FakeClipboard()
        clipboard.userCopies("de antes")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "clipboard-tests-\(UUID().uuidString)")!)
        settings.clipboardHistory = true
        let store = ClipboardStore(
            source: clipboard, picker: FakeColorPicker(), settings: settings,
            persistence: ClipboardPersistence(url: FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/h.json"))
        )
        store.poll()
        #expect(clipboard.reads == 0 && store.history.entries.isEmpty)
    }

    @Test func switchedOffItReadsNothing() {
        let (store, clipboard, _, _) = make(enabled: false)
        clipboard.userCopies("secreto")
        store.poll()
        #expect(clipboard.reads == 0 && store.history.entries.isEmpty && store.state == .off)
    }

    @Test func concealedCopiesAndIgnoredAppsAreNotKept() {
        let (store, clipboard, _, _) = make()
        clipboard.userCopies("contraseña", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        store.poll()
        clipboard.userCopies("de un gestor", types: ["public.utf8-plain-text"], from: "com.1password.1password")
        store.poll()
        // Pasa un sondeo ya en otra app (la copia se atribuye también a la app del sondeo anterior)
        clipboard.frontmostBundleID = "com.apple.Safari"
        store.poll()
        clipboard.userCopies("normal", types: ["public.utf8-plain-text"], from: "com.apple.Safari")
        store.poll()
        #expect(store.history.entries.map(\.text) == ["normal"])
        // Lo saltado ni se lee
        #expect(clipboard.reads == 1)
    }

    @Test func theIgnoredListCanBeChanged() {
        let (store, clipboard, _, settings) = make()
        settings.clipboardIgnoredApps = ["com.example.secreta"]
        clipboard.userCopies("de la app", from: "com.example.secreta")
        store.poll()
        clipboard.frontmostBundleID = "com.apple.Safari"
        store.poll()
        clipboard.userCopies("de un gestor", from: "com.1password.1password")
        store.poll()
        // La de la lista nueva no se guardó, y la del gestor de siempre (ya fuera de la lista) sí
        #expect(store.history.entries.map(\.text) == ["de un gestor"])
    }

    // macOS pregunta cada vez que una app lee el portapapeles en modo «preguntar»: no se lee solo
    @Test func withoutAlwaysAllowNothingIsReadAndOldContentIsNotIngestedLater() {
        let (store, clipboard, _, _) = make(behavior: .ask)
        clipboard.userCopies("mientras no hay permiso")
        store.poll()
        #expect(clipboard.reads == 0 && store.state == .needsAllow)
        // Llega el permiso: lo de antes sigue sin leerse; lo nuevo, sí
        clipboard.accessBehavior = .alwaysAllow
        store.poll()
        #expect(clipboard.reads == 0 && store.state == .recording)
        clipboard.userCopies("ya con permiso")
        store.poll()
        #expect(store.history.entries.map(\.text) == ["ya con permiso"])
        // Y si se retira, deja de leer
        clipboard.accessBehavior = .alwaysDeny
        clipboard.userCopies("otra")
        store.poll()
        #expect(store.history.entries.count == 1 && store.state == .denied)
    }

    // MARK: Pedir el acceso

    @Test func enablingItFromTheModuleReadsOnceToLetMacOSAsk() {
        let (store, clipboard, _, settings) = make(enabled: false, behavior: .unasked)
        clipboard.userCopies("lo que había")
        #expect(store.state == .off)
        store.requestAccess()
        #expect(settings.clipboardHistory)
        #expect(clipboard.reads == 1 && store.history.entries.isEmpty)
        // El usuario contestó «preguntar»: queda pendiente de elegir «Permitir»
        clipboard.accessBehavior = .ask
        store.poll()
        #expect(store.state == .needsAllow)
    }

    @Test func theFirstAccessIsAskedOnlyWithAClick() {
        let (store, clipboard, _, _) = make(behavior: .unasked)
        #expect(store.state == .needsFirstAccess)
        // Sin clic, ni una lectura, por muchas vueltas que dé
        for _ in 0..<5 { store.poll() }
        #expect(clipboard.reads == 0)
        store.requestAccess()
        #expect(clipboard.reads == 1)
    }

    @Test func turningItOffForgetsEverythingAndRemovesTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        let (store, clipboard, _, settings) = make(persist: true, url: url)
        store.start()
        defer { store.stop() }
        clipboard.userCopies("algo")
        store.poll()
        #expect(store.history.entries.count == 1 && FileManager.default.fileExists(atPath: url.path))
        settings.clipboardHistory = false
        // El ajuste se atiende en el hilo principal: hay que dejarle sitio (esperando sin bloquearlo)
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.history.entries.isEmpty)
    }

    // MARK: Disco

    @Test func theHistoryIsOnlyWrittenToDiskWhenAsked() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        let (memoryOnly, clipboard, _, _) = make(persist: false, url: url)
        clipboard.userCopies("solo en memoria")
        memoryOnly.poll()
        #expect(memoryOnly.history.entries.count == 1 && !FileManager.default.fileExists(atPath: url.path))

        let (saving, other, _, _) = make(persist: true, url: url)
        other.userCopies("va al disco")
        saving.poll()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(ClipboardPersistence(url: url).load().map(\.text) == ["va al disco"])
    }

    @Test func aSavedHistoryIsLoadedOnStart() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        try ClipboardPersistence(url: url).save([ClipboardEntry(text: "guardada", date: Date(timeIntervalSince1970: 100))])
        let (store, _, _, _) = make(persist: true, url: url)
        store.start()
        defer { store.stop() }
        #expect(store.history.entries.map(\.text) == ["guardada"])
        // Sin pedirlo, lo que hubiera en disco no se carga
        let (memory, _, _, _) = make(persist: false, url: url)
        memory.start()
        defer { memory.stop() }
        #expect(memory.history.entries.isEmpty)
    }

    @Test func clearingTheHistoryEmptiesTheFileToo() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        let (store, clipboard, _, _) = make(persist: true, url: url)
        clipboard.userCopies("una")
        store.poll()
        store.clearHistory()
        #expect(store.history.entries.isEmpty && ClipboardPersistence(url: url).load().isEmpty)
    }

    // Lo que hay en disco pasa por las reglas de una copia nueva, y un archivo enorme no se lee
    @Test func aFileWithBadEntriesOrTooBigIsCleanedOrIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        let huge = String(repeating: "x", count: ClipboardHistory.maxTextLength + 1)
        try ClipboardPersistence(url: url).save([
            ClipboardEntry(id: "a", text: "buena", date: Date(timeIntervalSince1970: 100)),
            ClipboardEntry(id: "a", text: "repetida de id", date: Date(timeIntervalSince1970: 100)),
            ClipboardEntry(id: "b", text: huge, date: Date(timeIntervalSince1970: 100)),
        ])
        let (store, _, _, _) = make(persist: true, url: url)
        store.start()
        defer { store.stop() }
        #expect(store.history.entries.map(\.text) == ["buena", "repetida de id"])
        #expect(Set(store.history.entries.map(\.id)).count == 2)
        // Un archivo de más de 8 MB ni se lee
        let big = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/big.json")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: ClipboardPersistence.maxFileBytes + 1).write(to: big)
        #expect(ClipboardPersistence(url: big).load().isEmpty)
    }

    @Test func aBrokenFileIsJustAnEmptyHistory() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/history.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "esto no es json".write(to: url, atomically: true, encoding: .utf8)
        #expect(ClipboardPersistence(url: url).load().isEmpty)
        #expect(ClipboardPersistence(url: url.deletingLastPathComponent().appending(path: "no-existe.json")).load().isEmpty)
    }

    // MARK: Lo que se pulsa

    @Test func copyingAnEntryWritesItBack() {
        let (store, clipboard, _, _) = make()
        clipboard.userCopies("uno")
        store.poll()
        clipboard.userCopies("dos")
        store.poll()
        let uno = store.history.entries[1].id
        store.copy(entryID: uno)
        #expect(clipboard.writes == ["uno"] && store.message == ClipboardMessage(text: "Copiado", isError: false))
        // Un identificador que ya no existe no hace nada (la lista se movió entre que se vio y se pulsó)
        store.copy(entryID: "no-existe")
        #expect(clipboard.writes == ["uno"])
        // Sube arriba, y lo que escribe la propia app no vuelve a entrar como una copia nueva
        let reads = clipboard.reads
        store.poll()
        #expect(store.history.entries.map(\.text) == ["uno", "dos"] && clipboard.reads == reads)
        #expect(clipboard.concealedWrites == [false])
    }

    // Lo que escribe la propia app no es una copia del usuario: sin esto, el sondeo lo apuntaba como nuevo
    @Test func whatTheAppWritesItselfIsNeverRecorded() {
        let (store, clipboard, picker, _) = make()
        clipboard.userCopies(#"{"b":1,"a":2}"#)
        store.poll()
        let reads = clipboard.reads
        store.run(.jsonCompact)
        store.run(.uuid)
        picker.next = RGBColor(red: 1, green: 0, blue: 0)
        store.pickColor()
        store.copy(swatchAt: 0)
        store.poll()
        #expect(store.history.entries.map(\.text) == [#"{"b":1,"a":2}"#])
        // Y ni siquiera se leyó para comprobarlo
        #expect(clipboard.reads == reads + 1)
    }

    // El resultado de transformar una contraseña es tan secreto como ella: se marca como oculto, y nadie lo guarda
    @Test func theResultOfTransformingASecretIsConcealedToo() {
        let (store, clipboard, _, _) = make()
        clipboard.userCopies("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        store.poll()
        store.run(.base64Encode)
        #expect(clipboard.writes == ["aHVudGVyMg=="] && clipboard.concealedWrites == [true])
        store.poll()
        #expect(store.history.entries.isEmpty)
        // Un gestor de la lista, aunque no marque la copia
        clipboard.userCopies("otra", from: "com.1password.1password")
        store.run(.sha256)
        #expect(clipboard.concealedWrites == [true, true])
        // Una copia normal no se oculta
        clipboard.userCopies("normal", from: "com.apple.Safari")
        store.run(.sha256)
        #expect(clipboard.concealedWrites == [true, true, false])
    }

    // Copia en el gestor y cambia de app antes del siguiente sondeo: la copia sigue siendo del gestor
    @Test func aQuickAppSwitchDoesNotHideWhereACopyCameFrom() {
        let (store, clipboard, _, _) = make()
        clipboard.frontmostBundleID = "com.1password.1password"
        store.poll()
        clipboard.userCopies("una contraseña", from: "com.apple.Safari")
        store.poll()
        #expect(store.history.entries.isEmpty)
        // Ya con dos sondeos fuera del gestor, vuelve a guardar
        store.poll()
        clipboard.userCopies("normal", from: "com.apple.Safari")
        store.poll()
        #expect(store.history.entries.map(\.text) == ["normal"])
    }

    // Si el portapapeles cambia mientras se lee, el texto puede ser de otra copia cuyos tipos no se miraron: se descarta y se repite
    @Test func aCopyThatChangesWhileReadingIsReadAgainNextTime() {
        let (store, clipboard, _, _) = make()
        clipboard.userCopies("primera")
        clipboard.onRead = { [unowned clipboard] in
            clipboard.onRead = nil
            clipboard.userCopies("segunda", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        }
        store.poll()
        #expect(store.history.entries.isEmpty)
        // El siguiente sondeo ve la segunda, que es oculta, y no la guarda
        store.poll()
        #expect(store.history.entries.isEmpty)
        clipboard.userCopies("tercera")
        store.poll()
        #expect(store.history.entries.map(\.text) == ["tercera"])
    }

    @Test func whenMacOSWithholdsTheTextTheToolSaysSoInsteadOfClaimingItIsEmpty() {
        let (store, clipboard, _, _) = make(enabled: false, behavior: .ask)
        clipboard.userCopies("algo")
        clipboard.withholdsText = true
        store.run(.sha256)
        #expect(clipboard.writes.isEmpty && store.message == ClipboardMessage(text: "macOS no dejó leer el texto", isError: true))
        // Con «permitir siempre» y sin texto (una imagen), el motivo es otro
        let (images, bare, _, _) = make(enabled: false)
        bare.text = nil
        images.run(.sha256)
        #expect(images.message?.text == "Portapapeles sin texto")
    }

    @Test func aToolReadsTransformsWritesAndConfirms() {
        let (store, clipboard, _, _) = make(enabled: false)
        clipboard.userCopies(#"{"b":1,"a":2}"#)
        store.run(.jsonCompact)
        #expect(clipboard.writes == [#"{"a":2,"b":1}"#])
        #expect(store.message == ClipboardMessage(text: "JSON compactado", isError: false))
        #expect(clipboard.reads == 1)
    }

    // Si la entrada no vale, lo dice y no toca el portapapeles
    @Test func anInvalidInputLeavesTheClipboardAlone() {
        let (store, clipboard, _, _) = make(enabled: false)
        clipboard.userCopies("esto no es json")
        store.run(.jsonFormat)
        #expect(clipboard.writes.isEmpty && clipboard.text == "esto no es json")
        #expect(store.message == ClipboardMessage(text: "No es JSON válido", isError: true))
        // Sin nada copiado
        let (empty, bare, _, _) = make(enabled: false)
        empty.run(.sha256)
        #expect(bare.writes.isEmpty && empty.message?.text == "Portapapeles sin texto" && empty.message?.isError == true)
    }

    @Test func theUUIDToolNeedsNoReading() {
        let (store, clipboard, _, _) = make(enabled: false)
        store.run(.uuid)
        #expect(clipboard.reads == 0 && clipboard.writes.count == 1 && UUID(uuidString: clipboard.writes[0]) != nil)
    }

    @Test func aDeniedClipboardSaysSoInsteadOfPretendingItIsEmpty() {
        let (store, clipboard, _, _) = make(enabled: false, behavior: .alwaysDeny)
        clipboard.userCopies("algo")
        store.run(.sha256)
        #expect(clipboard.reads == 0 && clipboard.writes.isEmpty)
        #expect(store.message?.isError == true && store.message?.text.contains("Ajustes del Sistema") == true)
        // El UUID no lee, así que funciona
        store.run(.uuid)
        #expect(clipboard.writes.count == 1)
    }

    @Test func aNewMessageReplacesTheOldOne() async throws {
        let (store, clipboard, _, _) = make(enabled: false)
        clipboard.userCopies("a")
        store.run(.base64Encode)
        #expect(store.message?.text == "Codificado en base64")
        store.run(.sha256)
        #expect(store.message?.text == "SHA-256 copiado")
    }

    @Test func theModeIsRemembered() {
        let (store, _, _, _) = make()
        #expect(store.mode == .history && store.snapshot.mode == .history)
        store.setMode(.tools)
        #expect(store.snapshot.mode == .tools)
    }

    // MARK: Colores

    @Test func pickingAColorCopiesItsHexAndKeepsTheSwatch() {
        let (store, clipboard, picker, settings) = make(enabled: false)
        picker.next = RGBColor(red: 0.1, green: 0.5, blue: 0.9)
        var announced: [String] = []
        store.onColorCopied = { announced.append($0) }
        store.pickColor()
        #expect(picker.picks == 1 && clipboard.writes == ["#1A80E6"] && announced == ["#1A80E6"])
        #expect(store.colors.hexes == ["#1A80E6"] && settings.clipboardColors == ["#1A80E6"])
        // Cancelar (Esc) no hace nada
        picker.next = nil
        store.pickColor()
        #expect(clipboard.writes.count == 1 && announced.count == 1)
    }

    @Test func aSwatchCopiesItsValueAgain() {
        let (store, clipboard, picker, _) = make(enabled: false)
        picker.next = RGBColor(red: 1, green: 0, blue: 0)
        store.pickColor()
        picker.next = RGBColor(red: 0, green: 0, blue: 1)
        store.pickColor()
        #expect(store.colors.hexes == ["#0000FF", "#FF0000"])
        store.copy(swatchAt: 1)
        #expect(clipboard.writes.last == "#FF0000" && store.message?.text == "#FF0000 copiado")
        store.copy(swatchAt: 7)
        #expect(clipboard.writes.count == 3)
    }

    @Test func theSwatchesSurviveARestart() {
        let (first, _, picker, settings) = make(enabled: false)
        picker.next = RGBColor(red: 0, green: 1, blue: 0)
        first.pickColor()
        let restarted = ClipboardStore(
            source: FakeClipboard(), picker: FakeColorPicker(), settings: settings,
            persistence: ClipboardPersistence(url: FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString)/h.json"))
        )
        #expect(restarted.colors.hexes == ["#00FF00"])
    }

    // MARK: Lo que enseña el módulo

    @Test func theSnapshotShowsSixPreviews() {
        let (store, clipboard, _, _) = make()
        for index in 0..<8 {
            clipboard.userCopies("copia \(index)\ncon dos líneas")
            store.poll()
        }
        let snapshot = store.snapshot
        #expect(snapshot.rows.count == 6 && snapshot.state == .recording)
        #expect(snapshot.rows.first?.preview == "copia 7 con dos líneas")
    }

    @Test func theSettingsHaveTheirDefaultsAndAreRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "clipboard-settings-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        // El historial está apagado hasta que el usuario lo enciende, y nada va a disco
        #expect(!settings.clipboardHistory && !settings.clipboardPersist)
        #expect(settings.clipboardIgnoredApps == ClipboardFilter.defaultIgnoredApps && settings.clipboardColors.isEmpty)
        settings.clipboardHistory = true
        settings.clipboardPersist = true
        settings.clipboardIgnoredApps = ["com.example.x"]
        settings.clipboardColors = ["#112233"]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.clipboardHistory && reloaded.clipboardPersist)
        #expect(reloaded.clipboardIgnoredApps == ["com.example.x"] && reloaded.clipboardColors == ["#112233"])
    }
}
