import CoreAudio
import Foundation
import IOKit

// MARK: USB: velocidad, corriente concedida y si cuelga de un hub

public struct USBLinkInfo: Sendable, Equatable {
    public var speed: String
    public var allocatedMilliamps: Int?
    /// Hubs entre la base y el controlador del Mac, del más cercano al más lejano.
    public var hubs: [String]

    public init(speed: String, allocatedMilliamps: Int?, hubs: [String]) {
        self.speed = speed; self.allocatedMilliamps = allocatedMilliamps; self.hubs = hubs
    }

    public var isDirect: Bool { hubs.isEmpty }

    public var summary: String {
        let power = allocatedMilliamps.map { "\($0) mA concedidos" } ?? "corriente concedida: desconocida"
        let path = isDirect ? "directa al Mac" : "por \(hubs.map { "«\($0)»" }.joined(separator: " → "))"
        return "USB \(speed) · \(power) · \(path)"
    }

    /// Lo que macOS dice del puerto: es el contrato de corriente, no una medida de la tensión real.
    public static func read(vendor: Int = 0x9886, product: Int = 0x002C) -> USBLinkInfo? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let dict = matching as NSMutableDictionary
        dict["idVendor"] = vendor
        dict["idProduct"] = product
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != 0 else { return nil }
        defer { IOObjectRelease(device) }

        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        let speeds = [0: "baja (1,5 Mbit/s)", 1: "completa (12 Mbit/s)", 2: "alta (480 Mbit/s)", 3: "super (5 Gbit/s)"]
        let speed = number("Device Speed").flatMap { speeds[$0] } ?? "velocidad desconocida"

        var hubs: [String] = []
        var current = device
        IOObjectRetain(current)
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, "IOUSB", &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                var name = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(current, &name)
                hubs.append(String(cString: name))
            }
        }
        IOObjectRelease(current)
        return USBLinkInfo(speed: speed, allocatedMilliamps: number("UsbPowerSinkAllocation"), hubs: hubs)
    }
}

// MARK: USB: qué bases Astro hay enchufadas y qué interfaces enseñan

/// Cualquier dispositivo con el fabricante de Astro (`0x9886`) que macOS vea, con su ID de producto y sus interfaces.
/// Sirve para saber, sin tocar nada, si una base distinta (p. ej. la versión Xbox) se presenta con el mismo ID que la PlayStation/PC.
public struct AstroUSBDevice: Sendable, Equatable {
    public struct Interface: Sendable, Equatable {
        public var interfaceClass: Int
        public var subclass: Int
        public init(interfaceClass: Int, subclass: Int) { self.interfaceClass = interfaceClass; self.subclass = subclass }

        public var label: String {
            switch (interfaceClass, subclass) {
            case (1, 1): return "audio · control"
            case (1, 2): return "audio · flujo"
            case (1, _): return "audio"
            case (3, _): return "HID"
            case (255, _): return "específica del fabricante"
            default: return "clase \(interfaceClass)"
            }
        }
    }

    public var vendor: Int
    public var product: Int
    public var name: String
    public var interfaces: [Interface]

    public init(vendor: Int, product: Int, name: String, interfaces: [Interface]) {
        self.vendor = vendor; self.product = product; self.name = name; self.interfaces = interfaces
    }

    /// Lo que A50 Control sabe de ese ID: `002c` (posición PC) y `002a` (actualización) salen del Command Center; `002b` (posición PS) está medido en esta base.
    public var verdict: String {
        switch product {
        case 0x002C: return "la base que A50 Control ya maneja (PlayStation/PC)"
        case 0x002A: return "base en modo de actualización de firmware"
        case 0x002B: return "base con el interruptor en PS: solo audio, sin interfaz HID (A50 Control no puede configurarla; ponla en PC)"
        default: return "ID de producto que A50 Control NO conoce: no se habla con ella hasta comprobar su protocolo"
        }
    }

    public var summary: String {
        let id = String(format: "%04x:%04x", vendor, product)
        let counts = Dictionary(grouping: interfaces, by: \.label).map { "\($0.value.count)× \($0.key)" }.sorted().joined(separator: ", ")
        return "\(id) «\(name)» · \(interfaces.count) interfaces (\(counts)) → \(verdict)"
    }

    public static func list(vendor: Int = 0x9886) -> [AstroUSBDevice] {
        // Sin filtro de IOKit: con solo `idVendor` no devuelve nada (hace falta también `idProduct`); se filtra aquí.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        func number(_ entry: io_registry_entry_t, _ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        var found: [AstroUSBDevice] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard number(device, "idVendor") == vendor else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(device, &nameBuffer)
            let name = (IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)
                ?? String(cString: nameBuffer)

            var interfaces: [Interface] = []
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    if IOObjectConformsTo(child, "IOUSBHostInterface") != 0, let c = number(child, "bInterfaceClass") {
                        interfaces.append(Interface(interfaceClass: c, subclass: number(child, "bInterfaceSubClass") ?? 0))
                    }
                    IOObjectRelease(child)
                }
                IOObjectRelease(children)
            }
            found.append(AstroUSBDevice(vendor: vendor, product: number(device, "idProduct") ?? 0, name: name, interfaces: interfaces))
        }
        return found.sorted { $0.product < $1.product }
    }
}

// MARK: Audio: las tarjetas de la A50 y su tasa de muestreo

public struct A50AudioDevice: Sendable, Equatable {
    public let name: String
    public let id: UInt32
    public let sampleRate: Double
    public let inputChannels: Int
    public let outputChannels: Int
}

public enum A50Audio {
    public static func devices() -> [A50AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        func name(_ id: AudioObjectID) -> String? {
            var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr else { return nil }
            return cf?.takeRetainedValue() as String?
        }
        func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, raw) == noErr else { return 0 }
            let list = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        func rate(_ id: AudioObjectID) -> Double {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: Float64 = 0
            var s = UInt32(MemoryLayout<Float64>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        return ids.compactMap { id in
            guard let n = name(id), n.contains("A50") else { return nil }
            return A50AudioDevice(name: n, id: id, sampleRate: rate(id),
                                  inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                                  outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    /// La tarjeta del micrófono de la A50 (la «A50 Voice» que tiene entrada).
    /// «A50 Game» también declara canales de entrada, así que se prefiere la que se llama «Voice».
    public static func microphone() -> A50AudioDevice? {
        let withInput = devices().filter { $0.inputChannels > 0 }
        return withInput.first { $0.name.contains("Voice") } ?? withInput.first
    }
}

// MARK: Calidad del micrófono: huecos en lo capturado

public struct MicQualityReport: Sendable, Equatable {
    public var seconds: Double
    public var sampleRate: Double
    /// Nivel medio de los tramos con voz (dBFS); nil si no hubo voz.
    public var speechDBFS: Double?
    public var peakDBFS: Double
    public var clippedSamples: Int
    /// Instantes (s desde el inicio) donde la señal se corta en seco en mitad de la voz.
    public var cuts: [Double]

    public var verdict: [String] {
        var out = [String(format: "%.1f s a %d Hz · voz %@ · pico %.0f dBFS", seconds, Int(sampleRate),
                          speechDBFS.map { String(format: "%.0f dBFS", $0) } ?? "no detectada", peakDBFS)]
        if speechDBFS == nil {
            out.append(seconds > 0 && peakDBFS < -100
                ? "⚠ Silencio digital absoluto: el micrófono está silenciado (¿pluma levantada?) o no le llega señal."
                : "⚠ No se oyó voz: habla durante la prueba.")
            return out
        }
        if cuts.isEmpty {
            out.append("✔ Sin cortes en la captura local. Si en la llamada suena robótico, el fallo no está en el micrófono hasta aquí: red, CPU o la reducción de ruido de la app de videollamada.")
        } else {
            let at = cuts.prefix(5).map { String(format: "%.1f s", $0) }.joined(separator: ", ")
            out.append("⚠ \(cuts.count) posible\(cuts.count == 1 ? "" : "s") corte\(cuts.count == 1 ? "" : "s") en mitad de la voz (\(at)). El fallo ya está en el micrófono o el enlace de radio, antes de la videollamada. La puerta de ruido también puede producirlos: pruébalo en otro modo.")
        }
        if clippedSamples > 0 { out.append("⚠ \(clippedSamples) muestras saturadas: baja el nivel del micrófono.") }
        else if let s = speechDBFS, s < -30 { out.append("⚠ Voz baja (\(Int(s)) dBFS): sube el nivel del micrófono o acércalo a la boca.") }
        return out
    }
}

/// Busca huecos de silencio digital exacto de 2–150 ms con voz a ambos lados y bordes abruptos (sin fundido):
/// lo que dejan los paquetes perdidos. Una puerta de ruido que fundió a cero, o el silencio entre frases, no cuentan.
/// Es una heurística: no detecta voz «robótica» por culpa del códec, solo huecos.
public struct MicQualityAnalyzer {
    public let sampleRate: Double
    private var samples: [Float] = []
    private static let maxSeconds = 120.0

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public mutating func feed(_ chunk: UnsafeBufferPointer<Float>) {
        guard samples.count < Int(sampleRate * Self.maxSeconds) else { return }
        samples.append(contentsOf: chunk)
    }

    public mutating func feed(_ chunk: [Float]) { chunk.withUnsafeBufferPointer { feed($0) } }

    /// Lo capturado hasta ahora, para guardarlo y poder escucharlo.
    public var captured: [Float] { samples }

    public func finish() -> MicQualityReport {
        let n = samples.count, sr = sampleRate
        func rms(_ a: Int, _ b: Int) -> Double {
            guard a < b else { return 0 }
            var s = 0.0
            for i in a..<b { s += Double(samples[i]) * Double(samples[i]) }
            return (s / Double(b - a)).squareRoot()
        }
        func peak(_ a: Int, _ b: Int) -> Double {
            var m = 0.0
            for i in max(0, a)..<min(n, b) { m = max(m, Double(abs(samples[i]))) }
            return m
        }
        func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-9)) }

        let block = max(1, Int(sr * 0.010))
        var speechPower = 0.0, speechBlocks = 0
        var i = 0
        while i + block <= n {
            let r = rms(i, i + block)
            if db(r) > -40 { speechPower += r * r; speechBlocks += 1 }
            i += block
        }
        // Hay voz si al menos 0,3 s superan −40 dBFS y el pico llega a −30: el ruido de la habitación no cuenta.
        let enoughSpeech = speechBlocks >= Int(0.3 / 0.010) && db(peak(0, n)) > -30
        let speech: Double? = enoughSpeech ? db((speechPower / Double(speechBlocks)).squareRoot()) : nil

        var cuts: [Double] = []
        let minRun = max(2, Int(sr * 0.002)), maxRun = Int(sr * 0.150), edge = max(1, Int(sr * 0.0005))
        i = 0
        while i < n {
            guard abs(samples[i]) < 1e-7 else { i += 1; continue }
            var j = i
            while j < n && abs(samples[j]) < 1e-7 { j += 1 }
            let len = j - i
            if len >= minRun, len <= maxRun, i >= block, j + block <= n {
                let before = rms(i - block, i), after = rms(j, j + block)
                if db(before) > -38, db(after) > -38, peak(i - edge, i) > 0.3 * before, peak(j, j + edge) > 0.3 * after {
                    cuts.append(Double(i) / sr)
                }
            }
            i = j
        }
        let pk = peak(0, n)
        return MicQualityReport(seconds: Double(n) / sr, sampleRate: sr, speechDBFS: speech, peakDBFS: db(pk),
                                clippedSamples: samples.reduce(0) { $0 + (abs($1) >= 0.999 ? 1 : 0) }, cuts: cuts)
    }
}
