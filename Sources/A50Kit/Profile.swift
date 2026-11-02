import Foundation

/// Toda la configuración de la base que se puede leer y escribir, en un fichero de texto (el «Guardar / Cargar perfil»
/// del Command Center, pero con los 3 presets, el puerto de stream, el apagado automático y el brillo incluidos).
///
/// Cargar un perfil escribe los valores ACTIVOS de la base; para que sobrevivan a un reinicio hay que llamar a `saveValues()`.
public struct A50Profile: Equatable, Sendable {
    public var presets: [EQPreset]          // los 3 huecos, índices 1…3
    public var activePreset: Int
    public var mic: Int                     // %
    public var sidetone: Int                // %
    public var noiseGate: NoiseGateMode
    public var micEQ: Int
    public var alertVolume: Int             // %
    public var defaultBalance: Int          // 0 = juego … 255 = chat
    public var streamMic: Int               // % de la salida analógica trasera
    public var streamChat: Int
    public var streamGame: Int
    public var streamAux: Int
    public var autoShutoffMinutes: Int
    public var brightness: Int

    public init(presets: [EQPreset], activePreset: Int, mic: Int, sidetone: Int, noiseGate: NoiseGateMode, micEQ: Int,
                alertVolume: Int, defaultBalance: Int, streamMic: Int, streamChat: Int, streamGame: Int, streamAux: Int,
                autoShutoffMinutes: Int, brightness: Int) {
        self.presets = presets; self.activePreset = activePreset; self.mic = mic; self.sidetone = sidetone
        self.noiseGate = noiseGate; self.micEQ = micEQ; self.alertVolume = alertVolume; self.defaultBalance = defaultBalance
        self.streamMic = streamMic; self.streamChat = streamChat; self.streamGame = streamGame; self.streamAux = streamAux
        self.autoShutoffMinutes = autoShutoffMinutes; self.brightness = brightness
    }

    // MARK: Base ⇄ perfil

    /// Lee lo que la base tiene ACTIVO ahora.
    public static func read(from d: A50Device) throws -> A50Profile {
        A50Profile(
            presets: try A50Device.eqPresets.map { try d.eqPreset($0) },
            activePreset: try d.activeEQPreset(),
            mic: try d.slider(.mic), sidetone: try d.slider(.sideTone),
            noiseGate: try d.noiseGate(), micEQ: try d.micEQ(),
            alertVolume: try d.alertVolume(), defaultBalance: try d.defaultBalance(),
            streamMic: try d.slider(.streamPortMixMic), streamChat: try d.slider(.streamPortMixChat),
            streamGame: try d.slider(.streamPortMixGame), streamAux: try d.slider(.streamPortMixAux),
            autoShutoffMinutes: try d.autoShutoffMinutes(), brightness: try d.brightness())
    }

    /// Escribe el perfil en los valores activos de la base.
    public func apply(to d: A50Device) throws {
        for p in presets { try d.setEQPreset(p) }
        try d.setActiveEQPreset(activePreset)
        try d.setSlider(.mic, percent: mic)
        try d.setSlider(.sideTone, percent: sidetone)
        try d.setNoiseGate(noiseGate)
        try d.setMicEQ(micEQ)
        try d.setAlertVolume(alertVolume)
        try d.setDefaultBalance(defaultBalance)
        try d.setSlider(.streamPortMixMic, percent: streamMic)
        try d.setSlider(.streamPortMixChat, percent: streamChat)
        try d.setSlider(.streamPortMixGame, percent: streamGame)
        try d.setSlider(.streamPortMixAux, percent: streamAux)
        try d.setAutoShutoff(minutes: autoShutoffMinutes)
        try d.setBrightness(brightness)
    }

    // MARK: Fichero

    public enum ParseError: Error, CustomStringConvertible {
        case notAProfile
        case missing(String)
        case invalid(String)
        public var description: String {
            switch self {
            case .notAProfile: return "no es un perfil de A50 Control"
            case .missing(let k): return "falta «\(k)»"
            case .invalid(let k): return "valor no válido en «\(k)»"
            }
        }
    }

    private static let gateNames: [(NoiseGateMode, String)] = [(.streaming, "streaming"), (.night, "night"), (.home, "home"), (.tournament, "tournament")]

    /// Texto del perfil. El ancho de banda va en bruto (×4096) para que ida y vuelta sean exactas.
    public func text(exported: Date = Date()) -> String {
        var o = "# Perfil de A50 Control · ASTRO A50 Gen 4\n"
        o += "# Se carga con «Cargar perfil…» en la app o con `a50ctl profile import`. Es texto: se puede editar a mano.\n"
        o += "[A50Control]\nFormat=1\nExported=\(ISO8601DateFormatter().string(from: exported))\n\n"
        o += "[Microphone]\nLevel=\(mic)\nSidetone=\(sidetone)\nNoisegate=\(Self.gateNames.first { $0.0 == noiseGate }!.1)\nMic_EQ=\(micEQ)\n\n"
        o += "[Settings]\nAlert_Volume=\(alertVolume)\nDefault_Balance=\(defaultBalance)\nActive_Preset=\(activePreset)\n"
        o += "Automatic_Shutoff=\(autoShutoffMinutes)\nBrightness=\(brightness)\n\n"
        o += "[StreamPort]\nMicrophone=\(streamMic)\nChat=\(streamChat)\nGame=\(streamGame)\nAux=\(streamAux)\n"
        for p in presets {
            o += "\n[Preset_\(p.index)]\nName=\(p.name)\n"
            for (i, b) in p.bands.enumerated() {
                o += "Band_\(i + 1)=\(b.gain),\(b.frequency),\(b.bandwidth)\n"
            }
        }
        return o
    }

    public init(parsing text: String) throws {
        let ini = Self.ini(text)
        guard ini["A50Control"]?["Format"] == "1" else { throw ParseError.notAProfile }

        func int(_ section: String, _ key: String, _ range: ClosedRange<Int>) throws -> Int {
            guard let raw = ini[section]?[key] else { throw ParseError.missing("\(section)/\(key)") }
            guard let v = Int(raw), range.contains(v) else { throw ParseError.invalid("\(section)/\(key)") }
            return v
        }

        var presets: [EQPreset] = []
        for n in A50Device.eqPresets {
            let sec = "Preset_\(n)"
            guard let s = ini[sec] else { throw ParseError.missing(sec) }
            var bands: [EQBand] = []
            for i in 1...5 {
                guard let raw = s["Band_\(i)"] else { throw ParseError.missing("\(sec)/Band_\(i)") }
                let v = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard v.count == 3,
                      (EQBand.minGain...EQBand.maxGain).contains(v[0]),
                      (EQBand.minFrequency...EQBand.maxFrequency).contains(v[1]),
                      (i == 1 || i == 5) ? v[2] == 0 : (EQBand.minBandwidth...EQBand.maxBandwidth).contains(v[2])
                else { throw ParseError.invalid("\(sec)/Band_\(i)") }
                bands.append(EQBand(gain: v[0], frequency: v[1], bandwidth: v[2]))
            }
            guard let name = s["Name"], !name.isEmpty, name.utf8.count <= 20 else { throw ParseError.invalid("\(sec)/Name") }
            presets.append(EQPreset(index: n, name: name, bands: bands))
        }
        guard let gateText = ini["Microphone"]?["Noisegate"], let gate = Self.gateNames.first(where: { $0.1 == gateText })?.0
        else { throw ParseError.invalid("Microphone/Noisegate") }

        let shutoff = try int("Settings", "Automatic_Shutoff", 0...255)
        guard A50Device.autoShutoffChoices.contains(shutoff) else { throw ParseError.invalid("Settings/Automatic_Shutoff") }

        self.init(
            presets: presets, activePreset: try int("Settings", "Active_Preset", 1...3),
            mic: try int("Microphone", "Level", 0...100), sidetone: try int("Microphone", "Sidetone", 0...100),
            noiseGate: gate, micEQ: try int("Microphone", "Mic_EQ", 0...2),
            alertVolume: try int("Settings", "Alert_Volume", 0...100), defaultBalance: try int("Settings", "Default_Balance", 0...255),
            streamMic: try int("StreamPort", "Microphone", 0...100), streamChat: try int("StreamPort", "Chat", 0...100),
            streamGame: try int("StreamPort", "Game", 0...100), streamAux: try int("StreamPort", "Aux", 0...100),
            autoShutoffMinutes: shutoff,
            brightness: try int("Settings", "Brightness", A50Device.brightnessRange.lowerBound...A50Device.brightnessRange.upperBound))
    }

    /// INI mínimo: `[sección]`, `clave=valor`, `#` comentarios.
    private static func ini(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[section, default: [:]][String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
