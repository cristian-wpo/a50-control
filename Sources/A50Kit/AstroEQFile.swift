import Foundation

/// Formato `.astroeq` del ASTRO Command Center (INI de texto), para intercambiar presets con él.
///
///     [General]
///     Name=ASTRO
///     [Eq_Bands]
///     Eq_Band_1=6 … Eq_Freq_Band_1=90 … Eq_Bandwidth_2=2 (solo bandas 2–4)
public enum AstroEQFile {
    public struct Parsed {
        public var preset: EQPreset
        /// Valores que hubo que recortar al rango de la A50 Gen 4.
        public var warnings: [String]
    }

    public static func parse(_ text: String, index: Int = 1) throws -> Parsed {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard values["Eq_Band_1"] != nil else { throw A50Error.badResponse("no parece un fichero .astroeq") }

        var warnings: [String] = []
        func clamp(_ v: Double, _ range: ClosedRange<Double>, _ what: String) -> Double {
            let c = min(max(v, range.lowerBound), range.upperBound)
            if c != v { warnings.append("\(what): \(v) recortado a \(c)") }
            return c
        }
        let bands = (1...5).map { i -> EQBand in
            let gain = clamp(Double(values["Eq_Band_\(i)"] ?? "") ?? 0, Double(EQBand.minGain)...Double(EQBand.maxGain), "ganancia banda \(i)")
            let freq = clamp(Double(values["Eq_Freq_Band_\(i)"] ?? "") ?? 1000, Double(EQBand.minFrequency)...Double(EQBand.maxFrequency), "frecuencia banda \(i)")
            var bw = 0.0
            if (2...4).contains(i) {
                let ratio = Double(values["Eq_Bandwidth_\(i)"] ?? "") ?? 1
                bw = clamp((ratio * 4096).rounded(), Double(EQBand.minBandwidth)...Double(EQBand.maxBandwidth), "ancho banda \(i)")
            }
            return EQBand(gain: Int(gain.rounded()), frequency: Int(freq.rounded()), bandwidth: Int(bw))
        }
        return Parsed(preset: EQPreset(index: index, name: values["Name"] ?? "SIN NOMBRE", bands: bands), warnings: warnings)
    }

    public static func serialize(_ p: EQPreset) -> String {
        var out = "[General]\nName=\(p.name)\n\n[Eq_Bands]\n"
        for (i, b) in p.bands.enumerated() { out += "Eq_Band_\(i + 1)=\(b.gain)\n" }
        for (i, b) in p.bands.enumerated() { out += "Eq_Freq_Band_\(i + 1)=\(b.frequency)\n" }
        for i in 1...3 {
            let ratio = Double(p.bands[i].bandwidth) / 4096
            out += "Eq_Bandwidth_\(i + 1)=\(String(format: "%g", (ratio * 100).rounded() / 100))\n"
        }
        return out
    }
}
