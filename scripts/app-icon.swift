import AppKit

// Genera el ícono de YabaiBar («La isla»): una isla negra sobre un fondo oscuro, con el logo a la izquierda y tres
// escritorios a la derecha, el del medio activo. Escribe todos los tamaños del AppIcon.appiconset.
//
//   swift scripts/app-icon.swift packaging/icon/logo.png YabaiBar/Assets.xcassets/AppIcon.appiconset
//
// El logo (cerebro con circuito, en degradado azul y violeta) es del autor.
let arguments = CommandLine.arguments
guard arguments.count == 3, let logo = NSImage(contentsOfFile: arguments[1]) else {
    print("Uso: swift scripts/app-icon.swift <logo.png> <AppIcon.appiconset>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2])

// La plantilla de los íconos de macOS: lienzo de 1024 con el cuerpo de 824 centrado
let canvas: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

func drawIcon() {
    let squircle = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
    NSGradient(
        starting: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.13, alpha: 1),
        ending: NSColor(srgbRed: 0.17, green: 0.15, blue: 0.29, alpha: 1)
    )!.draw(in: squircle, angle: -90)

    // La isla ocupa casi todo el ancho
    let pill = NSRect(x: body.minX + 40, y: body.midY - 140, width: body.width - 80, height: 280)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: 140, yRadius: 140).fill()
    let border = NSBezierPath(roundedRect: pill.insetBy(dx: 2.5, dy: 2.5), xRadius: 137.5, yRadius: 137.5)
    border.lineWidth = 5
    NSColor.white.withAlphaComponent(0.14).setStroke()
    border.stroke()

    logo.draw(in: NSRect(x: pill.minX + 52, y: pill.midY - 113, width: 230, height: 226))

    // Tres escritorios: el del medio, el activo, más grande
    let dots: [(CGFloat, CGFloat, NSColor)] = [
        (pill.maxX - 290, 34, NSColor(srgbRed: 0.52, green: 0.72, blue: 0.92, alpha: 1)),
        (pill.maxX - 182, 47, NSColor(srgbRed: 0.59, green: 0.77, blue: 0.35, alpha: 1)),
        (pill.maxX - 78, 34, NSColor(srgbRed: 0.69, green: 0.66, blue: 0.93, alpha: 1)),
    ]
    for (x, radius, color) in dots {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - radius, y: pill.midY - radius, width: radius * 2, height: radius * 2)).fill()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / canvas)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Los tamaños de un ícono de macOS: 16, 32, 128, 256 y 512, cada uno a 1x y 2x
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: points * scale).write(to: output.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appending(path: "Contents.json"))
print("Ícono generado en \(output.path)")
