import CryptoKit
import Foundation

// Las herramientas de desarrollador del módulo Portapapeles (fase 43): cada una toma el texto del portapapeles, lo transforma y
// devuelve el resultado, que la app escribe en el portapapeles y confirma con un aviso. Puras: no tocan el portapapeles, y si la
// entrada no vale devuelven el motivo y no cambian nada.

enum DevTool: String, CaseIterable, Sendable {
    case jsonFormat, jsonCompact, base64Encode, base64Decode, urlEncode, urlDecode, jwt, uuid, timestamp, sha256

    /// Lo que dice el botón al pasar el puntero
    var title: String {
        switch self {
        case .jsonFormat: "JSON: formatear"
        case .jsonCompact: "JSON: compactar"
        case .base64Encode: "Base64: codificar"
        case .base64Decode: "Base64: decodificar"
        case .urlEncode: "URL: codificar"
        case .urlDecode: "URL: decodificar"
        case .jwt: "JWT: leer"
        case .uuid: "UUID nuevo"
        case .timestamp: "Timestamp ↔ fecha"
        case .sha256: "SHA-256"
        }
    }

    /// Lo que cabe dentro del botón
    var label: String {
        switch self {
        case .jsonFormat: "{ }"
        case .jsonCompact: "{}"
        case .base64Encode: "→64"
        case .base64Decode: "64→"
        case .urlEncode: "→%"
        case .urlDecode: "%→"
        case .jwt: "JWT"
        case .uuid: "UUID"
        case .timestamp: "⏱"
        case .sha256: "SHA"
        }
    }

    /// El UUID no necesita el portapapeles: lo genera
    var needsInput: Bool { self != .uuid }
}

struct DevToolResult: Equatable, Sendable {
    /// Lo que se escribe en el portapapeles
    var text: String
    /// La confirmación: «JSON formateado»
    var message: String
}

enum DevToolFailure: Error, Equatable, Sendable {
    case noText
    case tooLarge
    case invalid(String)

    var message: String {
        switch self {
        case .noText: "Portapapeles sin texto"
        case .tooLarge: "Texto demasiado grande"
        case .invalid(let reason): reason
        }
    }
}

enum DevToolbox {
    /// Más de un megabyte de texto no se transforma: congelaría la isla
    static let maxInputBytes = 1_000_000

    static func run(
        _ tool: DevTool, input: String?, now: Date = Date(), timeZone: TimeZone = .current, makeUUID: () -> UUID = UUID.init
    ) -> Result<DevToolResult, DevToolFailure> {
        if tool == .uuid { return .success(DevToolResult(text: makeUUID().uuidString, message: "UUID nuevo copiado")) }
        guard let input else { return .failure(.noText) }
        // Lo barato primero: el tamaño antes de recorrer un texto de varios megabytes
        guard input.utf8.count <= maxInputBytes else { return .failure(.tooLarge) }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noText) }
        switch tool {
        case .jsonFormat: return json(trimmed, pretty: true)
        case .jsonCompact: return json(trimmed, pretty: false)
        case .base64Encode: return .success(DevToolResult(text: Data(input.utf8).base64EncodedString(), message: "Codificado en base64"))
        case .base64Decode: return base64Decode(trimmed)
        case .urlEncode:
            let encoded = input.addingPercentEncoding(withAllowedCharacters: unreserved) ?? input
            return .success(DevToolResult(text: encoded, message: "URL codificada"))
        case .urlDecode:
            guard let decoded = trimmed.removingPercentEncoding else { return .failure(.invalid("URL mal codificada")) }
            return .success(DevToolResult(text: decoded, message: "URL decodificada"))
        case .jwt: return jwt(trimmed)
        case .timestamp: return timestamp(trimmed, timeZone: timeZone)
        case .sha256:
            let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            return .success(DevToolResult(text: digest, message: "SHA-256 copiado"))
        case .uuid: return .failure(.noText)
        }
    }

    /// Lo que no se escapa al codificar un componente de URL: letras, cifras y `-._~`
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    // MARK: JSON

    // Foundation no conserva el orden de las claves: salen ordenadas. Un número de más de 64 bits pasa a decimal
    private static func json(_ text: String, pretty: Bool) -> Result<DevToolResult, DevToolFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return .failure(.invalid("No es JSON válido"))
        }
        guard let output = write(object, pretty: pretty) else { return .failure(.invalid("Número fuera de rango")) }
        return .success(DevToolResult(text: output, message: pretty ? "JSON formateado" : "JSON compactado"))
    }

    /// Escribe un JSON ya leído. El lector acepta `1e999` y `-1e999` como infinito, y el escritor de Foundation los rechaza con una
    /// excepción de Objective-C que ni `try?` captura y cierra la app: se comprueba antes (`isValidJSONObject` mira que ningún número
    /// sea infinito ni NaN; el contenedor deja pasar un valor suelto como `42`)
    private static func write(_ object: Any, pretty: Bool) -> String? {
        guard JSONSerialization.isValidJSONObject([object]) else { return nil }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: object, options: options)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Una fecha de un año razonable (hasta el 9999): lo que cabe en un timestamp sin desbordar
    private static let maxSeconds: Double = 253_402_300_799

    // MARK: Base64

    /// Acepta base64 normal y el de las URL (`-` y `_`), con o sin relleno y con saltos de línea
    static func decodeBase64(_ text: String) -> Data? {
        var cleaned = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty else { return nil }
        cleaned += String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: cleaned)
    }

    private static func base64Decode(_ text: String) -> Result<DevToolResult, DevToolFailure> {
        guard let data = decodeBase64(text) else { return .failure(.invalid("No es base64")) }
        guard let decoded = String(data: data, encoding: .utf8) else { return .failure(.invalid("El resultado no es texto")) }
        return .success(DevToolResult(text: decoded, message: "Decodificado de base64"))
    }

    // MARK: JWT

    // Solo se lee: la firma no se verifica (no hay clave) y el aviso lo dice
    private static func jwt(_ text: String) -> Result<DevToolResult, DevToolFailure> {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 2, let header = jsonObject(fromBase64: parts[0]), let payload = jsonObject(fromBase64: parts[1]),
              header is [String: Any], let claims = payload as? [String: Any] else {
            return .failure(.invalid("No es un JWT"))
        }
        guard let prettyHeader = write(header, pretty: true), let prettyClaims = write(claims, pretty: true) else {
            return .failure(.invalid("Número fuera de rango"))
        }
        var output = "// cabecera\n\(prettyHeader)\n\n// contenido\n\(prettyClaims)"
        let iso = ISO8601DateFormatter()
        for (key, label) in [("iat", "emitido"), ("nbf", "válido desde"), ("exp", "caduca")] {
            // Una fecha fuera de lo razonable no se convierte
            if let seconds = claims[key] as? Double ?? (claims[key] as? Int).map(Double.init), seconds.isFinite, abs(seconds) < maxSeconds {
                output += "\n\(label): \(iso.string(from: Date(timeIntervalSince1970: seconds)))"
            }
        }
        return .success(DevToolResult(text: output, message: "JWT leído (sin verificar)"))
    }

    private static func jsonObject(fromBase64 part: String) -> Any? {
        decodeBase64(part).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }

    // MARK: Timestamp

    /// Un número es un timestamp (segundos, o milisegundos si tiene 12 cifras o más) y da la fecha en local y en ISO 8601; una
    /// fecha (ISO 8601, o «2026-11-13 14:00:00» en hora local) da los segundos y los milisegundos
    private static func timestamp(_ text: String, timeZone: TimeZone) -> Result<DevToolResult, DevToolFailure> {
        if let value = Double(text), text.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "." }) {
            let seconds = abs(value) >= 100_000_000_000 ? value / 1000 : value
            guard seconds.isFinite, abs(seconds) < maxSeconds else { return .failure(.invalid("Timestamp demasiado grande")) }
            let date = Date(timeIntervalSince1970: seconds)
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = timeZone
            local.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let whole = seconds == seconds.rounded()
            let isoText = whole ? ISO8601DateFormatter().string(from: date) : iso.string(from: date)
            return .success(DevToolResult(text: "\(local.string(from: date)) (hora local)\n\(isoText)", message: "Convertido a fecha"))
        }
        guard let date = parseDate(text, timeZone: timeZone) else { return .failure(.invalid("No es fecha ni timestamp")) }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < maxSeconds else { return .failure(.invalid("Fecha demasiado lejana")) }
        return .success(DevToolResult(text: "\(Int(seconds.rounded(.down)))\n\(Int((seconds * 1000).rounded()))", message: "Convertido a timestamp"))
    }

    private static func parseDate(_ text: String, timeZone: TimeZone) -> Date? {
        // Con huso (`Z` o `-05:00`), con o sin fracciones de segundo
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        // Sin huso: en hora local. Cada formato tiene que casar con el texto entero (el formateador ISO 8601 solo de fecha ignoraría
        // lo que sobra y «2026-11-13 14:00:00» saldría como la medianoche)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
