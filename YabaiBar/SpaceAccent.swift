import SwiftUI

// Color de cada espacio: los mismos acentos, en el mismo orden, que el tema liquid-glass de SketchyBar
enum SpaceAccent {
    static let palette: [UInt32] = [
        0x8AB4FF, 0x7EE787, 0xFFB86C, 0xD2A8FF, 0x7FE0D4, 0xFF9CB4, 0xFFD98A, 0x86CEFA, 0xC6C9FF, 0xFF8A80,
    ]

    static func hex(for index: Int) -> UInt32 {
        palette[((index - 1) % palette.count + palette.count) % palette.count]
    }

    static func color(for index: Int) -> Color {
        let hex = hex(for: index)
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
