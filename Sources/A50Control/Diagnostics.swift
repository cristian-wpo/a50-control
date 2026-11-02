import A50Kit
import AVFoundation
import AppKit
import SwiftUI

enum MicTestState: Equatable {
    case idle
    case asking
    case recording(secondsLeft: Int)
    case done([String])
    case failed(String)

    var busy: Bool {
        switch self {
        case .asking, .recording: return true
        default: return false
        }
    }
}

/// Registro de incidencias (cortes del USB y del enlace de los auriculares, marcas del usuario) y prueba del micrófono.
/// Todo en el hilo principal.
final class Diagnostics: ObservableObject {
    @Published var incidents: [String] = []
    @Published var usb: USBLinkInfo?
    @Published var micTest: MicTestState = .idle
    @Published var hasTake = false
    @Published var playing = false

    let logURL: URL
    private let takeURL: URL
    private var captureToken: UUID?
    private var player: AVAudioPlayer?
    private(set) var lastReport: MicQualityReport?

    static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/A50 Control/incidencias.log")

    init(logURL: URL = Diagnostics.defaultLogURL) {
        self.logURL = logURL
        takeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/es.verticelabs.a50control/prueba-micro.caf")
        hasTake = FileManager.default.fileExists(atPath: takeURL.path)
        // Lo ocurrido antes de abrir la app también cuenta: las últimas líneas del registro.
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            incidents = Array(text.split(separator: "\n").suffix(30).map(String.init))
        }
    }

    // MARK: Registro

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func log(_ text: String, at date: Date = Date()) {
        let line = "\(Self.stamp.string(from: date))  \(text)"
        incidents.append(line)
        if incidents.count > 30 { incidents.removeFirst(incidents.count - 30) }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data((line + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: logURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: logURL)
            }
        } catch { /* el registro es ayuda: si no se puede escribir, la lista en pantalla sigue */ }
    }

    func mark(state: String) { log("★ Marcado por ti: suena robótico ahora — \(state)") }

    func refreshUSB() { usb = USBLinkInfo.read() }

    // MARK: Prueba del micrófono

    func runMicTest(seconds: Int = 10) {
        guard !micTest.busy else { return }
        stopPlayback()
        guard let device = A50Audio.microphone() else {
            micTest = .failed("No encuentro el micrófono de la A50: ¿está la base conectada?")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            capture(device, seconds: seconds)
        case .notDetermined:
            micTest = .asking
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.capture(device, seconds: seconds) } else { self.micTest = .failed(Self.denied) }
                }
            }
        default:
            micTest = .failed(Self.denied)
        }
    }

    private static let denied = "Sin permiso de micrófono. Concédelo en Ajustes del Sistema → Privacidad y seguridad → Micrófono → A50 Control."

    private func capture(_ device: A50AudioDevice, seconds: Int) {
        // CoreAudio directo sobre la tarjeta del micro: AVAudioEngine comparte una sola unidad de entrada y salida,
        // y al fijarle la tarjeta Voice arrastraba también su salida y no entregaba muestras.
        do {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput,
                                                  mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device.id, &addr, 0, nil, &size, &asbd) == noErr else {
                throw CaptureError("no pude leer el formato de «\(device.name)»")
            }
            let float32 = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
            guard float32, asbd.mSampleRate > 0 else {
                throw CaptureError("formato de entrada no soportado (\(asbd.mBitsPerChannel) bits, \(Int(asbd.mSampleRate)) Hz)")
            }
            let rate = asbd.mSampleRate
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let stride = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? channels : 1

            let analyzer = LockedAnalyzer(sampleRate: rate)
            var proc: AudioDeviceIOProcID?
            let queue = DispatchQueue(label: "es.verticelabs.a50control.mic", qos: .userInteractive)
            var st = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, queue) { _, inData, _, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                guard let first = list.first, let raw = first.mData else { return }
                let p = raw.assumingMemoryBound(to: Float.self)
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
                analyzer.feed((0..<frames).map { p[$0 * stride] })   // el primer canal
            }
            guard st == noErr, let proc else { throw CaptureError("no pude abrir «\(device.name)» (error \(st))") }
            st = AudioDeviceStart(device.id, proc)
            guard st == noErr else {
                AudioDeviceDestroyIOProcID(device.id, proc)
                throw CaptureError("no pude arrancar la captura (error \(st))")
            }
            let token = UUID()
            captureToken = token
            micTest = .recording(secondsLeft: seconds)
            for s in 1...seconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(s)) { [weak self] in
                    guard let self, self.captureToken == token else { return }
                    if s < seconds { self.micTest = .recording(secondsLeft: seconds - s); return }
                    AudioDeviceStop(device.id, proc)
                    AudioDeviceDestroyIOProcID(device.id, proc)
                    self.captureToken = nil
                    let (report, samples) = analyzer.take()
                    self.lastReport = report
                    if report.seconds < 0.5 {
                        self.micTest = .failed("No llegó audio del micrófono de la A50 (¿lo tiene otra app en exclusiva?).")
                        self.log("Prueba de micrófono: no llegó audio")
                        return
                    }
                    self.hasTake = (try? self.writeTake(samples, rate: rate)) != nil
                    self.micTest = .done(report.verdict)
                    self.log("Prueba de micrófono (\(Int(report.seconds)) s a \(Int(report.sampleRate)) Hz): "
                        + (report.speechDBFS == nil ? "sin voz" : report.cuts.isEmpty ? "sin cortes" : "\(report.cuts.count) posibles cortes"))
                }
            }
        } catch {
            captureToken = nil
            micTest = .failed("No se pudo grabar: \(error.localizedDescription)")
        }
    }

    private func writeTake(_ samples: [Float], rate: Double) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CaptureError("no hay muestras que guardar") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try FileManager.default.createDirectory(at: takeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AVAudioFile(forWriting: takeURL, settings: format.settings).write(from: buffer)
    }

    private struct CaptureError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    func playTake() {
        guard let p = try? AVAudioPlayer(contentsOf: takeURL) else { return }
        player = p
        p.play()
        playing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.3) { [weak self] in self?.playing = false }
    }

    func stopPlayback() { player?.stop(); player = nil; playing = false }
}

/// El analizador se alimenta desde el hilo de audio y se lee desde el principal.
private final class LockedAnalyzer {
    private let lock = NSLock()
    private var analyzer: MicQualityAnalyzer
    init(sampleRate: Double) { analyzer = MicQualityAnalyzer(sampleRate: sampleRate) }
    func feed(_ chunk: [Float]) { lock.lock(); analyzer.feed(chunk); lock.unlock() }
    func take() -> (MicQualityReport, [Float]) { lock.lock(); defer { lock.unlock() }; return (analyzer.finish(), analyzer.captured) }
}

// MARK: Qué cuenta como incidencia (funciones puras: se prueban sin el aparato)

extension A50Model {
    static func describeLinkChange(from old: LinkState, to new: LinkState, usb: USBLinkInfo?) -> String? {
        switch (old, new) {
        case (.connected, .noBase): return "La base USB desapareció del Mac (desconexión o reinicio del USB)"
        case (.connected, .error(let e)): return "Fallo de comunicación con la base: \(e)"
        case (.noBase, .connected), (.error, .connected): return "La base USB vuelve a estar conectada" + (usb.map { " · \($0.summary)" } ?? "")
        default: return nil
        }
    }

    static func describeHeadsetChange(old: HeadsetStatus?, new: HeadsetStatus?) -> String? {
        guard let old, let new else { return nil }
        if old.isOn != new.isOn { return new.isOn ? "Auriculares encendidos (enlace de radio establecido)" : "Auriculares apagados o enlace de radio perdido" }
        if old.isDocked != new.isDocked { return new.isDocked ? "Auriculares puestos en la base" : "Auriculares sacados de la base" }
        return nil
    }

    var stateLine: String {
        var parts: [String] = []
        if let h = headset { parts.append("auriculares \(h.isOn ? "encendidos" : "apagados"), \(h.isDocked ? "en la base" : "fuera de la base")") }
        if let b = battery { parts.append("batería \(b.percent) %\(b.isCharging ? " cargando" : "")") }
        parts.append("micrófono \(Int(mic)) % · puerta de ruido \(gate) · EQ micro \(micEQ + 1)")
        if let u = diagnostics.usb { parts.append(u.summary) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Vista

struct DiagnosticsSection: View {
    @EnvironmentObject var m: A50Model
    var body: some View { DiagnosticsBody(diag: m.diagnostics, state: m.stateLine) }
}

private struct DiagnosticsBody: View {
    @ObservedObject var diag: Diagnostics
    let state: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usb = diag.usb {
                let ok = usb.isDirect && (usb.allocatedMilliamps ?? 0) >= 500
                Label(usb.summary, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("La base no informa de la calidad del enlace de radio, así que las interferencias no se pueden medir. Aquí queda anotado cuándo se cae el USB o el enlace, y puedes marcar el momento en que suena mal.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(diag.micTest.busy ? "Grabando…" : "Probar micrófono (10 s)") { diag.runMicTest() }
                    .disabled(diag.micTest.busy)
                if diag.hasTake && !diag.micTest.busy {
                    Button(diag.playing ? "Parar" : "Escuchar") { diag.playing ? diag.stopPlayback() : diag.playTake() }
                }
            }.controlSize(.small)
            switch diag.micTest {
            case .idle: Text("Habla 10 s como en una videollamada y escúchalo después: si aquí suena bien, el fallo está en la red o en la app de llamadas.").font(.caption2).foregroundStyle(.secondary)
            case .asking: Text("Concede el permiso de micrófono en el aviso de macOS…").font(.caption).foregroundStyle(.blue)
            case .recording(let s): Text("Habla ahora… \(s) s").font(.caption).foregroundStyle(.blue)
            case .failed(let e): Text(e).font(.caption).foregroundStyle(.orange)
            case .done(let lines): ForEach(lines, id: \.self) { Text($0).font(.caption) }
            }

            Divider()
            Button("Marcar: suena robótico ahora") { diag.mark(state: state) }.controlSize(.small)
            if !diag.incidents.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(diag.incidents.suffix(5).enumerated()), id: \.offset) {
                        Text($0.element).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Abrir el registro") { NSWorkspace.shared.open(diag.logURL) }.controlSize(.small).buttonStyle(.link)
            }
        }
        .padding(.top, 4)
        .onAppear { diag.refreshUSB() }
    }
}

// MARK: Autotest (`A50Control --oculto --autotest-diag <informe.txt>` y `--autotest-micro <informe.txt>`)

extension Diagnostics {
    static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Lógica del registro sin el aparato: qué se anota, y que llega al fichero.
    static func runSelfTest(report path: String) {
        var log: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { log.append("\(ok ? "OK   " : "FALLA") \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
        let tmp = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("incidencias-prueba.log")
        try? "".write(to: tmp, atomically: true, encoding: .utf8)
        let d = Diagnostics(logURL: tmp)
        let usb = USBLinkInfo(speed: "completa (12 Mbit/s)", allocatedMilliamps: 500, hubs: [])
        let on = HeadsetStatus(isOn: true, isDocked: false), off = HeadsetStatus(isOn: false, isDocked: false)

        check("conectada → sin base se anota", A50Model.describeLinkChange(from: .connected, to: .noBase, usb: nil)?.contains("desapareció") == true)
        check("sin base → conectada se anota con el USB", A50Model.describeLinkChange(from: .noBase, to: .connected, usb: usb)?.contains("500 mA") == true)
        check("error de comunicación se anota", A50Model.describeLinkChange(from: .connected, to: .error("timeout"), usb: nil)?.contains("timeout") == true)
        check("buscando → conectada NO se anota (es el arranque)", A50Model.describeLinkChange(from: .searching, to: .connected, usb: usb) == nil)
        check("conectada → conectada NO se anota", A50Model.describeLinkChange(from: .connected, to: .connected, usb: usb) == nil)
        check("auriculares encendidos → apagados se anota", A50Model.describeHeadsetChange(old: on, new: off)?.contains("enlace de radio perdido") == true)
        check("sin cambio de auriculares NO se anota", A50Model.describeHeadsetChange(old: on, new: on) == nil)

        // Selector de predefinidos: qué cuenta como «prueba» (un predefinido que la base no tiene guardado en ese hueco).
        let cine = EQLibrary.all[3]
        check("predefinido en un hueco cuyo guardado es otro = prueba",
              A50Model.audition(of: cine.preset(index: 3), savedName: "STUDIO")?.name == cine.name)
        check("el mismo ya guardado en ese hueco = preset del usuario", A50Model.audition(of: cine.preset(index: 3), savedName: cine.name) == nil)
        var retouched = cine.preset(index: 3)
        retouched.bands[1].gain += 1
        check("predefinido retocado a mano ya no es prueba", A50Model.audition(of: retouched, savedName: "STUDIO") == nil)
        var own = cine.preset(index: 1)
        own.name = "ASTRO"
        check("un preset propio no es prueba", A50Model.audition(of: own, savedName: "ASTRO") == nil)
        check("sin preset leído no es prueba", A50Model.audition(of: nil, savedName: "STUDIO") == nil)

        d.log("prueba uno")
        d.mark(state: "estado de prueba")
        let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        check("el registro llega al fichero", lines.count == 2 && lines[0].hasSuffix("prueba uno") && lines[1].contains("★ Marcado por ti"), "\(lines.count) líneas")
        let d2 = Diagnostics(logURL: tmp)
        check("al reabrir se recuperan las líneas anteriores", d2.incidents.count == 2)

        log.append(log.contains { $0.hasPrefix("FALLA") } ? "RESULTADO: FALLA" : "RESULTADO: OK")
        try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Captura real de 3 s del micrófono de la A50 (pide permiso la primera vez). Solo comprueba el camino, no juzga la voz.
    func runMicSelfTest(report path: String) {
        var log: [String] = []
        func finish() {
            log.append(log.contains { $0.hasPrefix("FALLA") || $0.hasPrefix("PENDIENTE") } ? "RESULTADO: INCOMPLETO" : "RESULTADO: OK")
            try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        log.append("permiso de micrófono al empezar: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 sin decidir, 2 denegado, 3 concedido)")
        runMicTest(seconds: 3)
        var waited = 0
        func poll() {
            waited += 1
            switch micTest {
            case .done(let lines):
                lines.forEach { log.append("      \($0)") }
                if let r = lastReport {
                    let expected = A50Audio.microphone()?.sampleRate
                    let arrived = r.seconds >= 2.5 && r.sampleRate == expected
                    log.append("\(arrived ? "OK   " : "FALLA") llegaron muestras: \(String(format: "%.2f", r.seconds)) s a \(Int(r.sampleRate)) Hz (la tarjeta anuncia \(Int(expected ?? 0)) Hz)")
                    // Pico de −180 dBFS = ceros exactos: con la pluma levantada la A50 silencia el micro, no es un fallo del camino.
                    log.append(r.peakDBFS > -100 ? "OK    la señal no es silencio digital (pico \(Int(r.peakDBFS)) dBFS)"
                               : "PENDIENTE silencio digital absoluto: ¿micro silenciado con la pluma levantada?")
                } else { log.append("FALLA no hay informe de la captura") }
                log.append("\(hasTake ? "OK   " : "FALLA") queda la toma para escucharla")
                finish()
            case .failed(let e):
                log.append((e.hasPrefix("Sin permiso") ? "PENDIENTE " : "FALLA ") + e); finish()
            default:
                if waited > 90 { log.append("PENDIENTE el permiso de micrófono no se concedió en 90 s"); finish() } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: poll)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: poll)
    }
}
