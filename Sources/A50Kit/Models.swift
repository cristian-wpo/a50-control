import Foundation

public enum A50Error: Error, CustomStringConvertible {
    case notConnected
    case openFailed(IOReturnCode)
    case writeFailed(IOReturnCode)
    case timeout
    case headsetNotConnected
    case requestFailed(String)
    case badResponse(String)
    case outOfRange(String)

    public var description: String {
        switch self {
        case .notConnected: return "No hay base A50 Gen 4 conectada por USB (9886:002c)."
        case .openFailed(let r): return "No se pudo abrir la interfaz HID (IOReturn 0x\(String(UInt32(bitPattern: r), radix: 16)))."
        case .writeFailed(let r): return "Fallo al enviar a la base (IOReturn 0x\(String(UInt32(bitPattern: r), radix: 16)))."
        case .timeout: return "La base no respondió en 3 s."
        case .headsetNotConnected: return "Los auriculares están apagados y fuera de la base."
        case .requestFailed(let m): return "La base rechazó la petición: \(m)"
        case .badResponse(let m): return "Respuesta inesperada: \(m)"
        case .outOfRange(let m): return "Valor fuera de rango: \(m)"
        }
    }
}

public typealias IOReturnCode = Int32

public struct BatteryStatus: Equatable, Sendable {
    public let isCharging: Bool
    public let percent: Int
}

public struct HeadsetStatus: Equatable, Sendable {
    public let isOn: Bool
    public let isDocked: Bool
    public init(isOn: Bool, isDocked: Bool) { self.isOn = isOn; self.isDocked = isDocked }
}

public struct FirmwareVersion: Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public var description: String { "\(major).\(minor)" }
}

public struct DeviceInfo: Equatable, Sendable, CustomStringConvertible {
    public let vendorID: Int
    public let productID: Int
    public let buildTime: DateComponents
    public var description: String { String(format: "%04x:%04x", vendorID, productID) }
}

public enum NoiseGateMode: UInt8, CaseIterable, Sendable {
    case streaming = 0, night = 1, home = 2, tournament = 3
}

/// Deslizadores de la base. `streamPortMix*` solo afectan a la StreamPort (A50 MixAmp TX).
public enum Slider: UInt8, CaseIterable, Sendable {
    case streamPortMixMic = 0, streamPortMixChat, streamPortMixGame, streamPortMixAux, mic, sideTone
}

/// Una banda del ecualizador. Las bandas 1 y 5 son shelf (ancho 0).
public struct EQBand: Equatable, Sendable {
    public static let minGain = -7, maxGain = 7
    public static let minFrequency = 80, maxFrequency = 15_000
    /// El ancho es un múltiplo de la frecuencia central multiplicado por 4096.
    public static let minBandwidth = Int(4096 * 0.1), maxBandwidth = Int(4096 * 3.0)

    public var gain: Int
    public var frequency: Int
    public var bandwidth: Int

    public init(gain: Int, frequency: Int, bandwidth: Int) {
        self.gain = gain; self.frequency = frequency; self.bandwidth = bandwidth
    }
    /// Ancho de banda en octavas-ish (múltiplo de la frecuencia central), p. ej. 0.5.
    public var bandwidthRatio: Double { Double(bandwidth) / 4096 }
}

public struct EQPreset: Equatable, Sendable {
    public var index: Int
    public var name: String
    public var bands: [EQBand]
}
