// Genera los PNG del icono de la app: diadema y almohadillas verdes con 5 barras de ecualizador (las 5 bandas del EQ)
// sobre fondo grafito. Es un dibujo propio, sin símbolos del sistema.
// Uso: swift make-icon.swift <carpeta.iconset existente>   y luego   iconutil -c icns <carpeta.iconset> -o AppIcon.icns
import AppKit

guard CommandLine.arguments.count > 1 else { print("falta la carpeta .iconset"); exit(1) }
let dir = CommandLine.arguments[1]

let green = NSColor(calibratedRed: 0.30, green: 0.86, blue: 0.56, alpha: 1)
let bars: [CGFloat] = [0.10, 0.18, 0.26, 0.16, 0.08]   // alturas relativas: una curva de EQ

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.06

    // Fondo: cuadrado redondeado en degradado grafito.
    let body = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
        xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.24, green: 0.26, blue: 0.33, alpha: 1),
    ])!.draw(in: body, angle: 90)

    // Diadema: semicircunferencia que termina en el centro de cada almohadilla.
    let cx = s * 0.5, cy = s * 0.42, r = s * 0.27
    let band = NSBezierPath()
    band.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: 180)
    band.lineWidth = s * 0.07
    band.lineCapStyle = .butt
    green.setStroke()
    band.stroke()

    // Almohadillas.
    for x in [cx - r, cx + r] {
        let cup = NSBezierPath(
            roundedRect: NSRect(x: x - s * 0.065, y: cy - s * 0.16, width: s * 0.13, height: s * 0.28),
            xRadius: s * 0.05, yRadius: s * 0.05)
        green.setFill()
        cup.fill()
    }

    // Barras del ecualizador entre las almohadillas.
    let bw = s * 0.04, gap = s * 0.04
    let total = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
    var x = cx - total / 2
    let mid = cy - s * 0.02
    NSColor(white: 0.96, alpha: 0.95).setFill()
    for h in bars {
        let bh = s * h
        NSBezierPath(roundedRect: NSRect(x: x, y: mid - bh / 2, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
        x += bw + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    try png(px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
print("PNG escritos en \(dir)")
