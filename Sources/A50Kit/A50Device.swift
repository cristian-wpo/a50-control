import Foundation

/// Base + auriculares Astro A50 Gen 4. Todas las llamadas son síncronas y
/// bloquean hasta la respuesta (≤3 s): llámalas fuera del hilo principal.
///
/// Protocolo: ingeniería inversa de Tom Dryer (eh-fifty, MIT).
public final class A50Device {
    enum Cmd {
        static let deviceInfo: UInt8 = 0x03
        static let headsetStatus: UInt8 = 0x54
        static let baseFirmwareMinor: UInt8 = 0x55
        static let save: UInt8 = 0x61
        static let setSlider: UInt8 = 0x62
        static let setEQGain: UInt8 = 0x63
        static let setNoiseGate: UInt8 = 0x64
        static let setActiveEQ: UInt8 = 0x67
        static let getSlider: UInt8 = 0x68
        static let getEQGain: UInt8 = 0x69
        static let getNoiseGate: UInt8 = 0x6A
        static let getActiveEQ: UInt8 = 0x6C
        static let setEQName: UInt8 = 0x6D
        static let getEQName: UInt8 = 0x6E
        static let setEQFreqBW: UInt8 = 0x6F
        static let getEQFreqBW: UInt8 = 0x70
        static let setMicEQ: UInt8 = 0x71
        static let getBalance: UInt8 = 0x72
        static let setDefaultBalance: UInt8 = 0x73
        static let setAutoShutoff: UInt8 = 0x74
        static let setBrightness: UInt8 = 0x75
        static let setAlertVolume: UInt8 = 0x76
        static let getDefaultBalance: UInt8 = 0x77
        static let getAutoShutoff: UInt8 = 0x78
        static let getBrightness: UInt8 = 0x79
        static let getAlertVolume: UInt8 = 0x7A
        static let getMicEQ: UInt8 = 0x7B
        static let getBattery: UInt8 = 0x7C
        static let headsetInfo: UInt8 = 0x83
        static let headsetFirmwareMinor: UInt8 = 0xD6
        static let headsetFirmwareMajor: UInt8 = 0xDA
    }

    public static let eqPresets = [1, 2, 3]
    public static let eqBands = [1, 2, 3, 4, 5]
    private static let dbOffset = 12

    /// Comandos cuya respuesta repite el código de la petición en el primer byte de datos
    /// (según el protocolo documentado); permite descartar respuestas de otro cliente.
    private static let echoing: Set<UInt8> = [
        Cmd.save, Cmd.setSlider, Cmd.setEQGain, Cmd.setActiveEQ, Cmd.getSlider, Cmd.getEQGain, Cmd.getNoiseGate,
        Cmd.setEQName, Cmd.getEQName, Cmd.setEQFreqBW, Cmd.getEQFreqBW, Cmd.setMicEQ, Cmd.setDefaultBalance, Cmd.setAlertVolume,
    ]

    private let hid: HIDTransport

    /// Eventos que la base manda por su cuenta (para investigar / reaccionar).
    public var onUnsolicitedReport: (([UInt8]) -> Void)? {
        get { hid.onUnsolicited }
        set { hid.onUnsolicited = newValue }
    }

    public init() throws { hid = try HIDTransport() }

    public func close() { hid.close() }

    /// Petición cruda para explorar: devuelve los bytes de datos de la respuesta.
    public func raw(_ type: UInt8, _ payload: [UInt8] = []) throws -> [UInt8] { try hid.request(type, payload) }

    // MARK: Estado

    public func batteryStatus() throws -> BatteryStatus {
        let r = try need(Cmd.getBattery, min: 1)
        return BatteryStatus(isCharging: r[0] & 0x80 != 0, percent: Int(r[0] & 0x7F))
    }

    public func headsetStatus() throws -> HeadsetStatus {
        let r = try need(Cmd.headsetStatus, min: 1)
        return HeadsetStatus(isOn: r[0] & 0x02 != 0, isDocked: r[0] & 0x01 != 0)
    }

    public func deviceInfo() throws -> DeviceInfo { try Self.imageHeader(need(Cmd.deviceInfo, min: 15)) }

    /// Solo responde con los auriculares en la base.
    public func headsetInfo() throws -> DeviceInfo { try Self.imageHeader(need(Cmd.headsetInfo, [0x01], min: 15)) }

    public func baseFirmware() throws -> FirmwareVersion {
        let info = try need(Cmd.deviceInfo, min: 25)
        let minor = try need(Cmd.baseFirmwareMinor, min: 1)
        return FirmwareVersion(major: Self.le32(info, 21), minor: Int(minor[0]))
    }

    public func headsetFirmware() throws -> FirmwareVersion {
        let major = try need(Cmd.headsetFirmwareMajor, [0x0A], min: 4)
        let minor = try need(Cmd.headsetFirmwareMinor, [0x0A], min: 1)
        return FirmwareVersion(major: Self.le32(major, 0), minor: Int(minor[0]))
    }

    // MARK: Ecualizador

    public func activeEQPreset() throws -> Int {
        let r = try need(Cmd.getActiveEQ, min: 1)
        guard Self.eqPresets.contains(Int(r[0])) else { throw A50Error.badResponse("preset activo \(r[0])") }
        return Int(r[0])
    }

    public func setActiveEQPreset(_ preset: Int) throws {
        try checkPreset(preset)
        _ = try need(Cmd.setActiveEQ, [UInt8(preset)], min: 2)
    }

    public func eqPresetName(_ preset: Int, saved: Bool = false) throws -> String {
        try checkPreset(preset)
        let r = try need(Cmd.getEQName, [UInt8(preset), saved ? 1 : 0], min: 3)
        return String(decoding: r.dropFirst(2).prefix { $0 > 0 }, as: UTF8.self)
    }

    public func setEQPresetName(_ preset: Int, _ name: String) throws {
        try checkPreset(preset)
        let encoded = Array(name.utf8.prefix(20)) + [0]
        _ = try need(Cmd.setEQName, [UInt8(preset), UInt8(encoded.count)] + encoded, min: 2)
    }

    /// Ganancias (dB) de las 5 bandas: activas y guardadas.
    public func eqGains(_ preset: Int) throws -> (active: [Int], saved: [Int]) {
        try checkPreset(preset)
        let r = try need(Cmd.getEQGain, [UInt8(preset)], min: 12)
        let all = r[2..<12].map { Int($0) - Self.dbOffset }
        return (Array(all[0..<5]), Array(all[5..<10]))
    }

    public func setEQGains(_ preset: Int, _ gains: [Int]) throws {
        try checkPreset(preset)
        guard gains.count == 5, gains.allSatisfy({ (EQBand.minGain...EQBand.maxGain).contains($0) }) else {
            throw A50Error.outOfRange("5 ganancias entre \(EQBand.minGain) y \(EQBand.maxGain) dB")
        }
        _ = try need(Cmd.setEQGain, [UInt8(preset)] + gains.map { UInt8($0 + Self.dbOffset) }, min: 2)
    }

    public func eqFrequencyAndBandwidth(_ preset: Int, band: Int, saved: Bool = false) throws -> (frequency: Int, bandwidth: Int) {
        try checkPreset(preset); try checkBand(band)
        let r = try need(Cmd.getEQFreqBW, [UInt8(preset), UInt8(band)], min: 11)
        func u16(_ i: Int) -> Int { Int(r[i]) | Int(r[i + 1]) << 8 }
        // Orden: ancho activo, ancho guardado, frecuencia activa, frecuencia guardada.
        return saved ? (u16(9), u16(5)) : (u16(7), u16(3))
    }

    public func setEQFrequencyAndBandwidth(_ preset: Int, band: Int, frequency: Int, bandwidth: Int) throws {
        try checkPreset(preset); try checkBand(band)
        guard (EQBand.minFrequency...EQBand.maxFrequency).contains(frequency) else {
            throw A50Error.outOfRange("frecuencia \(EQBand.minFrequency)–\(EQBand.maxFrequency) Hz")
        }
        if band == 1 || band == 5 {
            guard bandwidth == 0 else { throw A50Error.outOfRange("las bandas 1 y 5 son shelf: ancho 0") }
        } else {
            guard (EQBand.minBandwidth...EQBand.maxBandwidth).contains(bandwidth) else {
                throw A50Error.outOfRange("ancho \(EQBand.minBandwidth)–\(EQBand.maxBandwidth)")
            }
        }
        let payload: [UInt8] = [UInt8(preset), UInt8(band),
                                UInt8(bandwidth & 0xFF), UInt8(bandwidth >> 8),
                                UInt8(frequency & 0xFF), UInt8(frequency >> 8)]
        _ = try need(Cmd.setEQFreqBW, payload, min: 4)
    }

    /// Preset completo (nombre + 5 bandas) con los valores activos.
    public func eqPreset(_ preset: Int) throws -> EQPreset {
        let gains = try eqGains(preset).active
        let bands = try Self.eqBands.map { b -> EQBand in
            let fb = try eqFrequencyAndBandwidth(preset, band: b)
            return EQBand(gain: gains[b - 1], frequency: fb.frequency, bandwidth: fb.bandwidth)
        }
        return EQPreset(index: preset, name: try eqPresetName(preset), bands: bands)
    }

    /// El preset tal como está guardado en la base (lo que había antes de los cambios activos).
    public func savedEQPreset(_ preset: Int) throws -> EQPreset {
        let gains = try eqGains(preset).saved
        let bands = try Self.eqBands.map { b -> EQBand in
            let fb = try eqFrequencyAndBandwidth(preset, band: b, saved: true)
            return EQBand(gain: gains[b - 1], frequency: fb.frequency, bandwidth: fb.bandwidth)
        }
        return EQPreset(index: preset, name: try eqPresetName(preset, saved: true), bands: bands)
    }

    /// Escribe un preset completo (ganancias, frecuencias, anchos y nombre).
    public func setEQPreset(_ preset: EQPreset) throws {
        guard preset.bands.count == 5 else { throw A50Error.outOfRange("5 bandas") }
        try setEQGains(preset.index, preset.bands.map(\.gain))
        for (i, b) in preset.bands.enumerated() {
            try setEQFrequencyAndBandwidth(preset.index, band: i + 1, frequency: b.frequency, bandwidth: b.bandwidth)
        }
        try setEQPresetName(preset.index, preset.name)
    }

    // MARK: Mezcla, micrófono y avisos

    /// 0 = 100 % juego … 255 = 100 % chat. Refleja los botones de los auriculares.
    public func balance() throws -> Int { Int(try need(Cmd.getBalance, min: 1)[0]) }

    public func defaultBalance(saved: Bool = false) throws -> Int {
        Int(try need(Cmd.getDefaultBalance, [saved ? 1 : 0], min: 1)[0])
    }

    public func setDefaultBalance(_ value: Int) throws {
        guard (0...255).contains(value) else { throw A50Error.outOfRange("balance 0–255") }
        _ = try need(Cmd.setDefaultBalance, [UInt8(value)], min: 1)
    }

    public func alertVolume(saved: Bool = false) throws -> Int {
        Int(try need(Cmd.getAlertVolume, [saved ? 1 : 0], min: 1)[0])
    }

    public func setAlertVolume(_ percent: Int) throws {
        guard (0...100).contains(percent) else { throw A50Error.outOfRange("volumen 0–100") }
        _ = try need(Cmd.setAlertVolume, [UInt8(percent)], min: 1)
    }

    public func noiseGate(saved: Bool = false) throws -> NoiseGateMode {
        let r = try need(Cmd.getNoiseGate, min: 3)
        guard let mode = NoiseGateMode(rawValue: r[saved ? 2 : 1]) else { throw A50Error.badResponse("noise gate \(r[saved ? 2 : 1])") }
        return mode
    }

    public func setNoiseGate(_ mode: NoiseGateMode) throws {
        _ = try need(Cmd.setNoiseGate, [mode.rawValue], min: 1)
    }

    /// EQ del micrófono: 0, 1 o 2 (el significado exacto no está documentado).
    public func micEQ(saved: Bool = false) throws -> Int {
        Int(try need(Cmd.getMicEQ, [saved ? 1 : 0], min: 1)[0])
    }

    public func setMicEQ(_ preset: Int) throws {
        guard (0...2).contains(preset) else { throw A50Error.outOfRange("EQ de micro 0–2") }
        _ = try need(Cmd.setMicEQ, [UInt8(preset)], min: 1)
    }

    public func slider(_ slider: Slider, saved: Bool = false) throws -> Int {
        let r = try need(Cmd.getSlider, [slider.rawValue], min: 4)
        return Int(r[saved ? 3 : 2])
    }

    public func setSlider(_ slider: Slider, percent: Int) throws {
        guard (0...100).contains(percent) else { throw A50Error.outOfRange("0–100 %") }
        _ = try need(Cmd.setSlider, [slider.rawValue, UInt8(percent)], min: 2)
    }

    // MARK: Energía y brillo de la base

    /// Minutos sin movimiento tras los que se apagan los auriculares: las mismas cinco opciones del Command Center.
    public static let autoShutoffChoices = [10, 15, 20, 25, 30]
    /// La base acepta 20–70 y rechaza el resto (medido barriendo 1–120 en la base real).
    public static let brightnessRange = 20...70

    public func autoShutoffMinutes() throws -> Int { Int(try need(Cmd.getAutoShutoff, min: 1)[0]) }

    public func setAutoShutoff(minutes: Int) throws {
        guard Self.autoShutoffChoices.contains(minutes) else { throw A50Error.outOfRange("apagado automático: 10, 15, 20, 25 o 30 minutos") }
        _ = try need(Cmd.setAutoShutoff, [UInt8(minutes)], min: 1)
    }

    /// Brillo del LED de la base. La base devuelve nueve bytes iguales; se lee el primero.
    public func brightness() throws -> Int { Int(try need(Cmd.getBrightness, min: 1)[0]) }

    /// La base solo acepta el valor repetido en nueve bytes (con un solo byte responde VALUE_OUT_OF_RANGE).
    public func setBrightness(_ value: Int) throws {
        guard Self.brightnessRange.contains(value) else { throw A50Error.outOfRange("brillo \(Self.brightnessRange.lowerBound)–\(Self.brightnessRange.upperBound)") }
        _ = try need(Cmd.setBrightness, [UInt8](repeating: UInt8(value), count: 9), min: 0)
    }

    /// Persiste la configuración activa en la base. Tarda ~2 s. Es lo único que sobrevive a un reinicio.
    public func saveValues() throws { _ = try need(Cmd.save, min: 2) }

    // MARK: Utilidades

    private func need(_ type: UInt8, _ payload: [UInt8] = [], min: Int) throws -> [UInt8] {
        let r = try hid.request(type, payload, echoes: Self.echoing.contains(type))
        guard r.count >= min else { throw A50Error.badResponse("0x\(String(type, radix: 16)): \(r.count) bytes, esperaba ≥\(min)") }
        return r
    }

    private func checkPreset(_ p: Int) throws {
        guard Self.eqPresets.contains(p) else { throw A50Error.outOfRange("preset 1–3") }
    }

    private func checkBand(_ b: Int) throws {
        guard Self.eqBands.contains(b) else { throw A50Error.outOfRange("banda 1–5") }
    }

    private static func le32(_ b: [UInt8], _ at: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) }
    }

    private static func imageHeader(_ r: [UInt8]) -> DeviceInfo {
        let year = Int(r[8]) | Int(r[9]) << 8
        return DeviceInfo(
            vendorID: Int(r[4]) | Int(r[5]) << 8,
            productID: Int(r[6]) | Int(r[7]) << 8,
            buildTime: DateComponents(year: year, month: Int(r[10]), day: Int(r[11]),
                                      hour: Int(r[12]), minute: Int(r[13]), second: Int(r[14])))
    }
}
