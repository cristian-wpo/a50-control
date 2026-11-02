import A50Kit
import Foundation

/// Curva de respuesta aproximada del EQ de 5 bandas con filtros biquad (RBJ):
/// banda 1 = shelf de graves, bandas 2–4 = campanas, banda 5 = shelf de agudos.
/// El firmware no documenta su filtro exacto: es una guía visual, no una medida.
enum EQMath {
    static let sampleRate = 48_000.0

    static func responseDB(_ bands: [EQBand], at frequency: Double) -> Double {
        bands.enumerated().reduce(0) { $0 + bandDB($1.element, index: $1.offset, at: frequency) }
    }

    private static func bandDB(_ band: EQBand, index: Int, at f: Double) -> Double {
        guard band.gain != 0 else { return 0 }
        let a = pow(10, Double(band.gain) / 40)
        let w0 = 2 * Double.pi * Double(band.frequency) / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        let b: (Double, Double, Double), den: (Double, Double, Double)
        switch index {
        case 1...3:
            let q = 1 / max(band.bandwidthRatio, 0.05)
            let alpha = sinW / (2 * q)
            b = (1 + alpha * a, -2 * cosW, 1 - alpha * a)
            den = (1 + alpha / a, -2 * cosW, 1 - alpha / a)
        default:
            let alpha = sinW / 2 * 2.0.squareRoot()  // S = 1
            let t = 2 * a.squareRoot() * alpha
            if index == 0 {
                b = (a * ((a + 1) - (a - 1) * cosW + t), 2 * a * ((a - 1) - (a + 1) * cosW), a * ((a + 1) - (a - 1) * cosW - t))
                den = ((a + 1) + (a - 1) * cosW + t, -2 * ((a - 1) + (a + 1) * cosW), (a + 1) + (a - 1) * cosW - t)
            } else {
                b = (a * ((a + 1) + (a - 1) * cosW + t), -2 * a * ((a - 1) + (a + 1) * cosW), a * ((a + 1) + (a - 1) * cosW - t))
                den = ((a + 1) - (a - 1) * cosW + t, 2 * ((a - 1) - (a + 1) * cosW), (a + 1) - (a - 1) * cosW - t)
            }
        }
        let w = 2 * Double.pi * f / sampleRate
        func mag(_ c: (Double, Double, Double)) -> Double {
            let re = c.0 + c.1 * cos(w) + c.2 * cos(2 * w)
            let im = -(c.1 * sin(w) + c.2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(mag(b) / mag(den))
    }
}
