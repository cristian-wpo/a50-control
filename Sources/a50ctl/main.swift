import A50Kit
import Foundation

let usage = """
a50ctl — control de Astro A50 Gen 4 (base 9886:002c)

  status                       todo el estado de un vistazo
  battery                      batería y si carga
  eq                           los 3 presets con sus 5 bandas
  eq saved                     los 3 presets tal como están GUARDADOS en la base
  eq use <1-3>                 activa un preset
  eq gains <1-3> g1 g2 g3 g4 g5   ganancias en dB (-7…7)
  eq band <1-3> <1-5> <Hz> <ancho>   frecuencia y ancho (×4096; shelf = 0)
  eq library                   los predefinidos de A50 Control (con sus bandas)
  eq library test              carga cada predefinido en un preset libre, lo lee de vuelta y restaura
  eq load <nombre|n> <1-3>     carga un predefinido en un preset (activo, sin guardar)
  eq name <1-3> <texto>        renombra el preset
  eq export <1-3> <fichero>    guarda el preset como .astroeq (formato Command Center)
  eq import <fichero> <1-3>    carga un .astroeq en un preset (activo, sin guardar)
  balance [0-100]              mezcla por defecto: 0 = juego, 100 = chat
  sidetone [0-100]             retorno de tu voz en los auriculares
  mic [0-100]                  nivel del micrófono
  gate [streaming|night|home|tournament]
  micEQ [0-2]                  EQ del micrófono
  alert [0-100]                volumen de los avisos
  stream [mic|chat|game|aux [0-100]]   mezcla de la salida analógica trasera (Puerto de stream)
  shutoff [10|15|20|25|30]     minutos sin movimiento hasta que los auriculares se apagan
  brightness [20-70]           brillo del LED de la base
  profile export <fichero>     guarda TODA la configuración activa (3 presets, micro, stream, energía…) en un fichero
  profile import <fichero>     la carga en la base (activa, sin guardar)
  profile test                 exporta, cambia valores, reimporta y comprueba que todo vuelve; restaura
  usb                          bases Astro enchufadas: ID de producto e interfaces (no abre la base; sirve con cualquier ID)
  diag                         electricidad USB, tarjetas de audio y ajustes del micro (qué se puede medir y qué no)
  diag selftest                prueba del analizador de cortes del micrófono con señal sintética
  save                         guarda la configuración activa en la base
  raw <tipo> [bytes…]          petición cruda (hex), para explorar
  watch                        cambios de estado y eventos en vivo
  reconnect <n>                diagnóstico: n reintentos de conexión y puertos Mach abiertos

Sin `save`, los cambios son activos pero se pierden al reiniciar la base.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func int(_ s: String?, _ what: String) -> Int {
    guard let s, let v = Int(s) else { fail("falta o no es un número: \(what)") }
    return v
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

func printPreset(_ p: EQPreset, active: Bool) {
    print("  \(active ? "▶" : " ") \(p.index) «\(p.name)»")
    for (i, b) in p.bands.enumerated() {
        let kind = (i == 0 || i == 4) ? "shelf" : String(format: "Q×%.2f", b.bandwidthRatio)
        print(String(format: "      banda %d  %6d Hz  %+3d dB  %@", i + 1, b.frequency, b.gain, kind))
    }
}

/// Prueba contra el aparato: cada predefinido se escribe en un preset que NO está activo, se lee de vuelta
/// y se compara bit a bit; al final se restaura lo que había. Nada se guarda en la base.
func libraryTest(_ d: A50Device) throws {
    let active = try d.activeEQPreset()
    guard let slot = A50Device.eqPresets.first(where: { $0 != active }) else { fail("no hay un preset libre") }
    let original = try d.eqPreset(slot)
    print("Probando en el preset \(slot) «\(original.name)» (el activo es el \(active) y no se toca).")
    var bad = 0
    for e in EQLibrary.all {
        try d.setEQPreset(e.preset(index: slot))
        Thread.sleep(forTimeInterval: 0.15)
        let back = try d.eqPreset(slot)
        let ok = back == e.preset(index: slot)
        if !ok { bad += 1 }
        print("\(ok ? "OK   " : "FALLA") \(e.name)")
        if !ok { print("   esperaba \(e.bands.map { "\($0.gain)/\($0.frequency)/\($0.bandwidth)" }) «\(e.name)»\n   leí      \(back.bands.map { "\($0.gain)/\($0.frequency)/\($0.bandwidth)" }) «\(back.name)»") }
    }
    try d.setEQPreset(original)
    Thread.sleep(forTimeInterval: 0.15)
    let restored = try d.eqPreset(slot) == original
    print("\(restored ? "OK   " : "FALLA") restaurado el preset \(slot) «\(original.name)»")
    if bad > 0 || !restored { exit(1) }
    print("RESULTADO: OK (\(EQLibrary.all.count) predefinidos)")
}

/// Qué se puede saber de la electricidad, el audio y los ajustes del micro. La base NO informa de la calidad
/// del enlace por radio (no hay orden conocida ni en eh-fifty ni en el Command Center): eso no se puede medir.
func diag(_ d: A50Device) throws {
    print("— Electricidad (lo que concede el puerto; no mide la tensión real) —")
    if let usb = USBLinkInfo.read() {
        print("  \(usb.summary)")
        print(usb.isDirect ? "  ✔ Cuelga directa del Mac, sin hub de por medio." : "  ⚠ Cuelga de un hub: prueba con un puerto del propio Mac.")
        switch usb.allocatedMilliamps {
        case .some(let ma) where ma >= 500: print("  ✔ El puerto concede \(ma) mA (el máximo de USB 2.0).")
        case .some(let ma): print("  ⚠ El puerto concede solo \(ma) mA: puede faltarle corriente.")
        case .none: print("  ? macOS no informa de la corriente concedida.")
        }
    } else { print("  ⚠ La base no aparece en el USB.") }

    print("— Audio —")
    for a in A50Audio.devices() {
        let io = [a.inputChannels > 0 ? "entrada \(a.inputChannels) can." : nil, a.outputChannels > 0 ? "salida \(a.outputChannels) can." : nil]
        print("  \(a.name): \(Int(a.sampleRate)) Hz · \(io.compactMap { $0 }.joined(separator: " + "))")
    }
    if let mic = A50Audio.microphone() { print("  micrófono que se probará: «\(mic.name)» a \(Int(mic.sampleRate)) Hz") }
    print("  (la entrada del micro es de banda ancha a 16 kHz por diseño: las apps la reescalan)")

    print("— Auriculares y micrófono —")
    let hs = try d.headsetStatus()
    print("  \(hs.isOn ? "encendidos" : "apagados")\(hs.isDocked ? ", en la base" : ", fuera de la base")")
    if hs.isOn || hs.isDocked { let b = try d.batteryStatus(); print("  batería \(b.percent) %\(b.isCharging ? " (cargando)" : "")") }
    print("  micrófono \(try d.slider(.mic)) % · EQ micro \(try d.micEQ()) · puerta de ruido \(try d.noiseGate()) · sidetone \(try d.slider(.sideTone)) %")
    print("— Límite —\n  Interferencias de radio: la base no expone la calidad del enlace; no hay forma de medirla desde el Mac.")
}

/// Prueba del analizador con señal sintética: cortes abruptos (deben contarse) frente a fundidos de la puerta de
/// ruido, silencios largos y señal limpia (no deben contarse).
func diagSelfTest() {
    let sr = 16_000.0
    func voice(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            let s = sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 900 * t) + 0.3 * sin(2 * .pi * 2300 * t)
            return Float(0.25 * s * (0.7 + 0.3 * sin(2 * .pi * 3 * t)))
        }
    }
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "OK   " : "FALLA") \(name) — \(detail)")
        if !ok { failures += 1 }
    }
    func analyze(_ s: [Float]) -> MicQualityReport { var a = MicQualityAnalyzer(sampleRate: sr); a.feed(s); return a.finish() }

    check("señal limpia: sin cortes", analyze(voice(4)).cuts.isEmpty, "\(analyze(voice(4)).cuts)")

    var cut = voice(4)
    for i in Int(1.0 * sr)..<Int(1.0 * sr + 0.020 * sr) { cut[i] = 0 }
    for i in Int(2.5 * sr)..<Int(2.5 * sr + 0.008 * sr) { cut[i] = 0 }
    let r = analyze(cut)
    check("dos huecos abruptos (20 ms y 8 ms): 2 cortes en 1,0 s y 2,5 s",
          r.cuts.count == 2 && abs(r.cuts[0] - 1.0) < 0.01 && abs(r.cuts[1] - 2.5) < 0.01, "\(r.cuts)")

    var gate = voice(4)   // puerta de ruido: fundido de 20 ms, 100 ms de silencio, fundido de entrada
    let a0 = Int(2.0 * sr), fade = Int(0.020 * sr), hold = Int(0.100 * sr)
    for k in 0..<fade { gate[a0 + k] *= Float(1 - Double(k) / Double(fade)) }
    for k in 0..<hold { gate[a0 + fade + k] = 0 }
    for k in 0..<fade { gate[a0 + fade + hold + k] *= Float(Double(k) / Double(fade)) }
    check("puerta de ruido con fundidos: no es un corte", analyze(gate).cuts.isEmpty, "\(analyze(gate).cuts)")

    var silence = voice(4)   // silencio largo entre frases
    for i in Int(1.5 * sr)..<Int(2.5 * sr) { silence[i] = 0 }
    check("silencio de 1 s entre frases: no es un corte", analyze(silence).cuts.isEmpty, "\(analyze(silence).cuts)")

    var clip = voice(2)
    for i in 1000..<1010 { clip[i] = 1.0 }
    check("10 muestras saturadas", analyze(clip).clippedSamples == 10, "\(analyze(clip).clippedSamples)")
    check("nivel de voz y pico razonables", { let q = analyze(voice(2)); return q.speechDBFS.map { $0 > -30 && $0 < -5 } == true && q.peakDBFS < 0 }(),
          analyze(voice(2)).verdict.first ?? "")
    print(failures == 0 ? "RESULTADO: OK" : "RESULTADO: FALLA")
    if failures > 0 { exit(1) }
}

func status(_ d: A50Device) throws {
    let hs = try d.headsetStatus()
    print("Base        \(try d.deviceInfo()) · firmware \(try d.baseFirmware())")
    print("Auriculares \(hs.isOn ? "encendidos" : "apagados")\(hs.isDocked ? ", en la base" : "")")
    let b = try d.batteryStatus()
    print("Batería     \(b.percent) %\(b.isCharging ? " (cargando)" : "")")
    if hs.isOn || hs.isDocked, let fw = try? d.headsetFirmware() { print("Firmware    auriculares \(fw)") }
    let active = try d.activeEQPreset()
    print("EQ activo   \(active) «\(try d.eqPresetName(active))»")
    let bal = try d.balance()
    print("Balance     \(bal)/255 (\(Int((Double(bal) / 255 * 100).rounded())) % chat) · por defecto \(try d.defaultBalance())")
    print("Sidetone    \(try d.slider(.sideTone)) %")
    print("Micrófono   \(try d.slider(.mic)) % · EQ micro \(try d.micEQ()) · noise gate \(try d.noiseGate())")
    print("Avisos      \(try d.alertVolume()) %")
    print("Stream      micro \(try d.slider(.streamPortMixMic)) % · chat \(try d.slider(.streamPortMixChat)) % · juego \(try d.slider(.streamPortMixGame)) % · aux \(try d.slider(.streamPortMixAux)) %")
    print("Energía     apagado automático \(try d.autoShutoffMinutes()) min · brillo base \(try d.brightness())")
}

let streamKeys: [(String, Slider)] = [("mic", .streamPortMixMic), ("chat", .streamPortMixChat), ("game", .streamPortMixGame), ("aux", .streamPortMixAux)]

func profileTest(_ d: A50Device) throws {
    var bad = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "OK   " : "FALLA") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { bad += 1 }
    }
    let original = try A50Profile.read(from: d)
    let text = original.text()
    let parsed = try A50Profile(parsing: text)
    check("el texto del perfil se lee de vuelta idéntico", parsed == original)

    // Perfil distinto del actual: cambia stream, apagado, brillo, micro y el preset 3; lo carga y lo lee de la base.
    var changed = original
    changed.streamChat = original.streamChat == 40 ? 41 : 40
    changed.autoShutoffMinutes = original.autoShutoffMinutes == 20 ? 25 : 20
    changed.brightness = original.brightness == 50 ? 55 : 50
    changed.sidetone = original.sidetone == 33 ? 34 : 33
    changed.presets[2].bands[1].gain = original.presets[2].bands[1].gain == 3 ? 2 : 3
    try changed.apply(to: d)
    Thread.sleep(forTimeInterval: 0.5)
    let back = try A50Profile.read(from: d)
    check("un perfil cargado queda activo en la base (stream, apagado, brillo, sidetone, EQ)", back == changed,
          back == changed ? "" : "esperaba \(changed) leí \(back)")

    // Un fichero defectuoso se rechaza sin tocar la base.
    var broken = 0
    for bad in [text.replacingOccurrences(of: "Format=1", with: "Format=9"),
                text.replacingOccurrences(of: "Brightness=\(original.brightness)", with: "Brightness=5"),
                text.replacingOccurrences(of: "Automatic_Shutoff=\(original.autoShutoffMinutes)", with: "Automatic_Shutoff=7"),
                text.replacingOccurrences(of: "[Preset_2]", with: "[Otro]"),
                "basura"] {
        if (try? A50Profile(parsing: bad)) == nil { broken += 1 }
    }
    check("5 ficheros defectuosos rechazados", broken == 5, "\(broken)/5")

    try original.apply(to: d)
    Thread.sleep(forTimeInterval: 0.5)
    check("restaurado a lo que había", try A50Profile.read(from: d) == original)
    if bad > 0 { exit(1) }
    print("RESULTADO: OK")
}

func run(_ args: [String]) throws {
    guard let cmd = args.first else { print(usage); return }
    if cmd == "help" || cmd == "-h" || cmd == "--help" { print(usage); return }
    if cmd == "reconnect" { reconnect(int(args[safe: 1], "repeticiones")); return }
    if cmd == "diag", args[safe: 1] == "selftest" { diagSelfTest(); return }
    if cmd == "usb" {
        let found = AstroUSBDevice.list()
        if found.isEmpty { print("Ningún dispositivo Astro (0x9886) enchufado."); return }
        found.forEach { print($0.summary) }
        return
    }
    let d = try A50Device()
    defer { d.close() }
    let rest = Array(args.dropFirst())

    switch cmd {
    case "status": try status(d)
    case "battery":
        let b = try d.batteryStatus()
        print("\(b.percent) %\(b.isCharging ? " cargando" : "")")

    case "eq":
        switch rest.first {
        case nil:
            let active = try d.activeEQPreset()
            for p in A50Device.eqPresets { printPreset(try d.eqPreset(p), active: p == active) }
        case "saved":
            for p in A50Device.eqPresets { printPreset(try d.savedEQPreset(p), active: false) }
        case "use": try d.setActiveEQPreset(int(rest[safe: 1], "preset"))
        case "gains":
            let p = int(rest[safe: 1], "preset")
            try d.setEQGains(p, (2..<7).map { int(rest[safe: $0], "ganancia \($0 - 1)") })
        case "band":
            let p = int(rest[safe: 1], "preset"), band = int(rest[safe: 2], "banda")
            try d.setEQFrequencyAndBandwidth(p, band: band, frequency: int(rest[safe: 3], "Hz"), bandwidth: int(rest[safe: 4], "ancho"))
        case "library":
            if rest[safe: 1] == "test" { try libraryTest(d); break }
            for (i, e) in EQLibrary.all.enumerated() {
                print("  \(i + 1)  \(e.name) — \(e.summary)")
                print("      " + e.bands.map { String(format: "%+d dB a %d Hz", $0.gain, $0.frequency) }.joined(separator: " · "))
            }
        case "load":
            guard let key = rest[safe: 1], let entry = EQLibrary.find(key) else { fail("nombre o número de un predefinido (mira `eq library`)") }
            let slot = int(rest[safe: 2], "preset de destino (1-3)")
            try d.setEQPreset(entry.preset(index: slot))
            print("«\(entry.name)» cargado en el preset \(slot) (activo; usa `save` para que sobreviva).")
        case "name": try d.setEQPresetName(int(rest[safe: 1], "preset"), rest.dropFirst(2).joined(separator: " "))
        case "export":
            let p = try d.eqPreset(int(rest[safe: 1], "preset"))
            guard let path = rest[safe: 2] else { fail("falta el fichero .astroeq de destino") }
            try AstroEQFile.serialize(p).write(toFile: path, atomically: true, encoding: .utf8)
            print("Preset \(p.index) «\(p.name)» exportado a \(path)")
        case "import":
            guard let path = rest[safe: 1] else { fail("falta el fichero .astroeq") }
            let slot = int(rest[safe: 2], "preset de destino (1-3)")
            let parsed = try AstroEQFile.parse(String(contentsOfFile: path, encoding: .utf8), index: slot)
            parsed.warnings.forEach { print("aviso: \($0)") }
            try d.setEQPreset(parsed.preset)
            print("«\(parsed.preset.name)» cargado en el preset \(slot) (activo; usa `save` para que sobreviva).")
        default: fail(usage)
        }

    case "balance":
        if let v = rest.first { try d.setDefaultBalance(Int((Double(int(v, "balance")) / 100 * 255).rounded())) }
        let b = try d.defaultBalance()
        print("\(Int((Double(b) / 255 * 100).rounded())) % chat (\(b)/255)")
    case "sidetone": try sliderCmd(d, .sideTone, rest)
    case "mic": try sliderCmd(d, .mic, rest)
    case "gate":
        if let m = rest.first {
            guard let mode = NoiseGateMode.allCases.first(where: { "\($0)" == m }) else { fail("modos: streaming night home tournament") }
            try d.setNoiseGate(mode)
        }
        print(try d.noiseGate())
    case "micEQ":
        if let v = rest.first { try d.setMicEQ(int(v, "EQ micro")) }
        print(try d.micEQ())
    case "alert":
        if let v = rest.first { try d.setAlertVolume(int(v, "volumen")) }
        print(try d.alertVolume())
    case "stream":
        if let k = rest.first {
            guard let slider = streamKeys.first(where: { $0.0 == k })?.1 else { fail("canales: mic chat game aux") }
            if let v = rest[safe: 1] { try d.setSlider(slider, percent: int(v, "porcentaje")) }
            print("\(try d.slider(slider)) %")
        } else {
            for (k, s) in streamKeys { print("\(k): \(try d.slider(s)) %") }
        }
    case "shutoff":
        if let v = rest.first { try d.setAutoShutoff(minutes: int(v, "minutos")) }
        print("\(try d.autoShutoffMinutes()) min")
    case "brightness":
        if let v = rest.first { try d.setBrightness(int(v, "brillo")) }
        print(try d.brightness())
    case "profile":
        switch (rest.first, rest[safe: 1]) {
        case ("export", let path?):
            try A50Profile.read(from: d).text().write(toFile: path, atomically: true, encoding: .utf8)
            print("Perfil guardado en \(path)")
        case ("import", let path?):
            let profile = try A50Profile(parsing: String(contentsOfFile: path, encoding: .utf8))
            try profile.apply(to: d)
            print("Perfil cargado (activo; usa `save` para que sobreviva).")
        case ("test", nil): try profileTest(d)
        default: fail(usage)
        }
    case "save":
        try d.saveValues(); print("Guardado en la base.")

    case "raw":
        guard let t = rest.first, let type = UInt8(t.replacingOccurrences(of: "0x", with: ""), radix: 16) else { fail("tipo en hex") }
        let payload = rest.dropFirst().compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        print(hex(try d.raw(type, payload)))

    case "diag": try diag(d)
    case "watch": try watch(d)
    default: fail(usage)
    }
}

/// Con `A50_TEST_PRODUCT_ID=1` la base «no existe»: así se ejercita el reintento de la app con la base desenchufada.
func reconnect(_ n: Int) {
    func ports() -> Int {  // puertos Mach abiertos por este proceso
        var names: mach_port_name_array_t?, types: mach_port_type_array_t?
        var nameCount: mach_msg_type_number_t = 0, typeCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS else { return -1 }
        return Int(nameCount)
    }
    let before = ports()
    var notConnected = 0
    for _ in 0..<n {
        do { _ = try A50Device() } catch A50Error.notConnected { notConnected += 1 } catch { print("otro error: \(error)") }
    }
    let after = ports()
    print("\(n) reintentos (\(notConnected) «sin base») · puertos Mach abiertos \(before) → \(after) (+\(after - before))")
}

func sliderCmd(_ d: A50Device, _ s: Slider, _ rest: [String]) throws {
    if let v = rest.first { try d.setSlider(s, percent: int(v, "porcentaje")) }
    print("\(try d.slider(s)) %")
}

func watch(_ d: A50Device) throws {
    d.onUnsolicitedReport = { print("[evento] \(hex($0))") }
    var last = ""
    while true {
        let now = [
            "\(try d.headsetStatus())", "\(try d.batteryStatus())",
            "balance=\(try d.balance())", "eq=\(try d.activeEQPreset())",
        ].joined(separator: " · ")
        if now != last { print(now); last = now }
        Thread.sleep(forTimeInterval: 1)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

setlinebuf(stdout)  // `watch` y los demás sacan una línea a la vez aunque la salida sea un fichero o una tubería
do { try run(Array(CommandLine.arguments.dropFirst())) } catch { fail("\(error)") }
