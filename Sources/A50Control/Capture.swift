import AppKit

/// Modo de diagnóstico: `A50Control --ventana-eq --ventana-panel --capturar <carpeta>` vuelca cada
/// ventana propia a PNG y sale. Una app puede dibujarse a sí misma sin permiso de grabación de pantalla.
enum Capture {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capturar"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    static func run(into dir: String) {
        var n = 0
        for window in NSApp.windows where window.isVisible && window.contentView != nil && window.frame.width > 100 {
            guard let view = window.contentView, let layer = view.layer else { continue }
            let scale = window.backingScaleFactor
            let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            // La capa de SwiftUI viene volteada respecto al contexto de bitmap.
            ctx.translateBy(x: 0, y: view.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
            guard let image = ctx.makeImage() else { continue }
            let title = window.title.isEmpty ? "ventana\(n)" : window.title.replacingOccurrences(of: " ", with: "-")
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(title).png")
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url); n += 1 }
        }
        print("capturadas \(n) ventanas en \(dir)")
        NSApp.terminate(nil)
    }
}
