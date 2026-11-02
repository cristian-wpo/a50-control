import CoreAudio
import Foundation

/// Cambia los dispositivos de audio por defecto del Mac. La base A50 aparece como dos
/// tarjetas USB: «Astro A50 Game» (juego/música) y «Astro A50 Voice» (chat y micrófono).
enum AudioRouter {
    struct Device {
        let id: AudioObjectID
        let name: String
        let inputs: Int
        let outputs: Int
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { Device(id: $0, name: name($0), inputs: channels($0, input: true), outputs: channels($0, input: false)) }
    }

    static func name(_ id: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let r = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        return r == noErr ? (cf?.takeRetainedValue() as String?) ?? "" : ""
    }

    static func channels(_ id: AudioObjectID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Nombre del dispositivo por defecto actual (nil si no hay).
    static func defaultName(input: Bool) -> String? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return name(id)
    }

    @discardableResult
    static func setDefault(name wanted: String, input: Bool) -> Bool {
        guard var id = all().first(where: { $0.name == wanted && (input ? $0.inputs : $0.outputs) > 0 })?.id else { return false }
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    /// Salida «Game» y micrófono «Voice» de la A50, si están presentes.
    static func a50Names() -> (output: String?, input: String?) {
        let devices = all()
        return (devices.first { $0.name.contains("A50 Game") && $0.outputs > 0 }?.name,
                devices.first { $0.name.contains("A50 Voice") && $0.inputs > 0 }?.name)
    }
}
