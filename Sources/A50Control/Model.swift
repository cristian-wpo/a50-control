import A50Kit
import AppKit
import Foundation
import ServiceManagement
import UserNotifications

enum LinkState: Equatable {
    case searching
    case noBase
    case connected
    case error(String)
}

/// Lo que se lee de la base en cada sondeo. Los campos opcionales solo vienen en la lectura completa.
private struct Snapshot {
    var headset: HeadsetStatus?
    var battery: BatteryStatus?
    var activePreset: Int?
    var balance: Int?
    var presets: [Int: EQPreset]?
    var savedNames: [Int: String]?
    var sidetone: Int?
    var mic: Int?
    var alert: Int?
    var gate: NoiseGateMode?
    var micEQ: Int?
    var stream: [Slider: Int]?
    var autoShutoff: Int?
    var brightness: Int?
    var baseFW: String?
    var headsetFW: String?
}

/// Estado de la interfaz. Todo el acceso a la base ocurre en `io` (cola serie); las
/// propiedades @Published solo se tocan en el hilo principal.
final class A50Model: ObservableObject {
    @Published var link: LinkState = .searching {
        didSet {
            guard oldValue != link else { return }
            if link == .connected { diagnostics.refreshUSB() }
            if let line = Self.describeLinkChange(from: oldValue, to: link, usb: diagnostics.usb) { diagnostics.log(line) }
        }
    }
    @Published var headset: HeadsetStatus?
    @Published var battery: BatteryStatus?
    @Published var activePreset = 1
    @Published var presets: [Int: EQPreset] = [:]
    @Published var savedNames: [Int: String] = [:]  // nombres tal como los tiene GUARDADOS la base
    @Published var balance = 50.0  // 0 = juego … 100 = chat
    @Published var sidetone = 0.0
    @Published var mic = 0.0
    @Published var alert = 0.0
    @Published var gate: NoiseGateMode = .home
    @Published var micEQ = 0
    @Published var stream: [Slider: Double] = [.streamPortMixMic: 0, .streamPortMixChat: 0, .streamPortMixGame: 0, .streamPortMixAux: 0]
    @Published var autoShutoff = 15
    @Published var brightness = 70.0
    @Published var baseFW = ""
    @Published var headsetFW = ""
    @Published var notice: String?

    @Published var autoRoute: Bool { didSet { defaults.set(autoRoute, forKey: "autoRoute") } }
    @Published var batteryAlerts: Bool { didSet { defaults.set(batteryAlerts, forKey: "batteryAlerts") } }
    @Published var launchAtLogin: Bool

    let diagnostics = Diagnostics()
    let openEQOnLaunch = CommandLine.arguments.contains("--ventana-eq")
    let openPanelOnLaunch = A50Model.shouldOpenPanelOnLaunch

    private let defaults = UserDefaults.standard
    let io = DispatchQueue(label: "es.verticelabs.a50control.io")
    private var device: A50Device?                 // solo en io
    private var sentEQ: [Int: EQPreset] = [:]      // solo en io: lo último que sabemos que tiene la base
    private var lastFullAttempt = Date.distantPast  // solo en io
    private let lock = NSLock()
    private var queued: [String: (A50Device) throws -> Void] = [:]
    private var scheduled: Set<String> = []
    private var touched: [String: Date] = [:]      // main: último cambio del usuario por control
    private var timer: Timer?
    private var wasOn: Bool?
    private var savedRoute: (output: String?, input: String?)?
    private var lowNotified = Set<Int>()

    init() {
        defaults.register(defaults: ["batteryAlerts": true, "autoRoute": false])
        autoRoute = defaults.bool(forKey: "autoRoute")
        batteryAlerts = defaults.bool(forKey: "batteryAlerts")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if Bundle.main.bundleIdentifier != nil, batteryAlerts {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refresh(full: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh(full: false) }
    }

    // MARK: Conexión y sondeo

    func connect() -> A50Device? {
        if let device { return device }
        do {
            let d = try A50Device()
            device = d
            return d
        } catch A50Error.notConnected {
            post { self.link = .noBase }
        } catch {
            post { self.link = .error("\(error)") }
        }
        return nil
    }

    private static func isFatal(_ error: Error) -> Bool {
        switch error {
        case A50Error.timeout, A50Error.writeFailed, A50Error.openFailed: return true
        default: return false
        }
    }

    func handle(_ error: Error) {
        if Self.isFatal(error) {
            device?.close()
            device = nil
            post { self.link = .error("\(error)") }
        } else {
            post { self.say("\(error)") }
        }
    }

    /// Lectura que puede ser rechazada (p. ej. con los auriculares apagados): devuelve nil.
    /// Los fallos de comunicación sí se propagan.
    private func soft<T>(_ read: () throws -> T) throws -> T? {
        do { return try read() } catch {
            if Self.isFatal(error) { throw error }
            return nil
        }
    }

    func post(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    func refresh(full: Bool) {
        io.async { [self] in
            guard let d = connect() else { return }
            do {
                let hs = try soft { try d.headsetStatus() }
                let present = hs.map { $0.isOn || $0.isDocked } ?? false
                let bat: BatteryStatus? = present ? try soft({ try d.batteryStatus() }) : nil
                var snap = Snapshot(headset: hs, battery: bat,
                                    activePreset: try soft { try d.activeEQPreset() },
                                    balance: try soft { try d.balance() })
                let due = Date().timeIntervalSince(lastFullAttempt) > (full ? 0 : 10)
                if (full || sentEQ.isEmpty) && due {
                    lastFullAttempt = Date()
                    var all: [Int: EQPreset] = [:]
                    for p in A50Device.eqPresets { all[p] = try soft { try d.eqPreset(p) } }
                    if all.count == A50Device.eqPresets.count { sentEQ = all; snap.presets = all }
                    var names: [Int: String] = [:]
                    for p in A50Device.eqPresets { if let n = try soft({ try d.eqPresetName(p, saved: true) }) { names[p] = n } }
                    if names.count == A50Device.eqPresets.count { snap.savedNames = names }
                    snap.sidetone = try soft { try d.slider(.sideTone) }
                    snap.mic = try soft { try d.slider(.mic) }
                    snap.alert = try soft { try d.alertVolume() }
                    snap.gate = try soft { try d.noiseGate() }
                    snap.micEQ = try soft { try d.micEQ() }
                    var st: [Slider: Int] = [:]
                    for k in Self.streamChannels { if let v = try soft({ try d.slider(k) }) { st[k] = v } }
                    if st.count == Self.streamChannels.count { snap.stream = st }
                    snap.autoShutoff = try soft { try d.autoShutoffMinutes() }
                    snap.brightness = try soft { try d.brightness() }
                    snap.baseFW = try soft { "\(try d.baseFirmware())" }
                    if present { snap.headsetFW = try soft { "\(try d.headsetFirmware())" } }
                }
                post { self.apply(snap) }
            } catch {
                handle(error)
            }
        }
    }

    private func fresh(_ key: String) -> Bool {
        guard let t = touched[key] else { return true }
        return Date().timeIntervalSince(t) > 1.5
    }

    private func apply(_ s: Snapshot) {
        link = .connected
        if let line = Self.describeHeadsetChange(old: headset, new: s.headset) { diagnostics.log(line) }
        headset = s.headset
        battery = s.battery
        if let v = s.activePreset, fresh("preset") { activePreset = v }
        if let v = s.balance, fresh("balance") { balance = Double(v) / 255 * 100 }
        if let p = s.presets {
            for (k, v) in p where fresh("eq\(k)") && fresh("name\(k)") { presets[k] = v }
        }
        if let n = s.savedNames { savedNames = n }
        if let v = s.sidetone, fresh("sidetone") { sidetone = Double(v) }
        if let v = s.mic, fresh("mic") { mic = Double(v) }
        if let v = s.alert, fresh("alert") { alert = Double(v) }
        if let v = s.gate, fresh("gate") { gate = v }
        if let v = s.micEQ, fresh("micEQ") { micEQ = v }
        if let st = s.stream { for (k, v) in st where fresh("stream\(k.rawValue)") { stream[k] = Double(v) } }
        if let v = s.autoShutoff, fresh("autoShutoff") { autoShutoff = v }
        if let v = s.brightness, fresh("brightness") { brightness = Double(v) }
        if let v = s.baseFW { baseFW = v }
        if let v = s.headsetFW { headsetFW = v }
        react(to: s)
    }

    // MARK: Reacciones (audio y batería)

    private func react(to s: Snapshot) {
        let on = s.headset?.isOn ?? false
        if autoRoute, let was = wasOn, was != on { DispatchQueue.global().async { self.route(headsetOn: on) } }
        wasOn = on

        guard batteryAlerts, let b = s.battery else { return }
        if b.isCharging || b.percent > 30 { lowNotified.removeAll(); return }
        for threshold in [20, 10] where b.percent <= threshold && !lowNotified.contains(threshold) {
            lowNotified.insert(threshold)
            notify("Batería de los auriculares al \(b.percent) %", "Ponlos en la base para cargar.")
        }
    }

    private func route(headsetOn: Bool) {
        if headsetOn {
            let target = AudioRouter.a50Names()
            savedRoute = (AudioRouter.defaultName(input: false), AudioRouter.defaultName(input: true))
            if let out = target.output { AudioRouter.setDefault(name: out, input: false) }
            if let inp = target.input { AudioRouter.setDefault(name: inp, input: true) }
            post { self.say("Audio del Mac pasado a la A50") }
        } else if let saved = savedRoute {
            if let out = saved.output { AudioRouter.setDefault(name: out, input: false) }
            if let inp = saved.input { AudioRouter.setDefault(name: inp, input: true) }
            savedRoute = nil
            post { self.say("Audio del Mac devuelto a \(saved.output ?? "su salida anterior")") }
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func say(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.notice == text { self?.notice = nil } }
    }

    // MARK: Escrituras (agrupadas: si llegan varias seguidas, solo viaja la última)

    private func write(_ key: String, delay: TimeInterval = 0.05, _ job: @escaping (A50Device) throws -> Void) {
        touched[key] = Date()
        lock.lock()
        queued[key] = job
        let first = scheduled.insert(key).inserted
        lock.unlock()
        guard first else { return }
        io.asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let job = queued.removeValue(forKey: key)
            scheduled.remove(key)
            lock.unlock()
            guard let job, let d = connect() else { return }
            do { try job(d) } catch { handle(error) }
        }
    }

    func setPreset(_ n: Int) {
        activePreset = n
        write("preset", delay: 0) { try $0.setActiveEQPreset(n) }
    }

    func setBalance(_ percent: Double) {
        balance = percent
        write("balance") { try $0.setDefaultBalance(Int((percent / 100 * 255).rounded())) }
    }

    func setSidetone(_ v: Double) { sidetone = v; write("sidetone") { try $0.setSlider(.sideTone, percent: Int(v.rounded())) } }
    func setMic(_ v: Double) { mic = v; write("mic") { try $0.setSlider(.mic, percent: Int(v.rounded())) } }
    func setAlert(_ v: Double) { alert = v; write("alert") { try $0.setAlertVolume(Int(v.rounded())) } }
    func setGate(_ m: NoiseGateMode) { gate = m; write("gate", delay: 0) { try $0.setNoiseGate(m) } }
    func setMicEQ(_ n: Int) { micEQ = n; write("micEQ", delay: 0) { try $0.setMicEQ(n) } }

    // MARK: Puerto de stream, energía y brillo

    /// Los cuatro canales de la salida analógica trasera, en el orden en que se enseñan.
    static let streamChannels: [Slider] = [.streamPortMixMic, .streamPortMixChat, .streamPortMixGame, .streamPortMixAux]

    func setStream(_ k: Slider, _ v: Double) {
        stream[k] = v
        write("stream\(k.rawValue)") { try $0.setSlider(k, percent: Int(v.rounded())) }
    }

    /// Silenciar = nivel 0 recordando el anterior; al reactivar vuelve a él (la base no tiene un «mute» propio).
    func toggleStreamMute(_ k: Slider) {
        let key = "streamAntes\(k.rawValue)"
        let now = stream[k] ?? 0
        if now > 0 {
            defaults.set(now, forKey: key)
            setStream(k, 0)
        } else {
            let before = defaults.double(forKey: key)
            setStream(k, before > 0 ? before : 70)
        }
    }

    func setAutoShutoff(_ minutes: Int) { autoShutoff = minutes; write("autoShutoff", delay: 0) { try $0.setAutoShutoff(minutes: minutes) } }
    func setBrightness(_ v: Double) { brightness = v; write("brightness") { try $0.setBrightness(Int(v.rounded())) } }

    // MARK: Ecualizador

    func editBand(_ p: Int, _ i: Int, _ change: (inout EQBand) -> Void) {
        guard var preset = presets[p] else { return }
        change(&preset.bands[i])
        var b = preset.bands[i]
        b.gain = min(max(b.gain, EQBand.minGain), EQBand.maxGain)
        b.frequency = min(max(b.frequency, EQBand.minFrequency), EQBand.maxFrequency)
        b.bandwidth = (i == 0 || i == 4) ? 0 : min(max(b.bandwidth, EQBand.minBandwidth), EQBand.maxBandwidth)
        preset.bands[i] = b
        presets[p] = preset
        pushEQ(preset)
    }

    func rename(_ p: Int, _ name: String) {
        guard var preset = presets[p] else { return }
        preset.name = String(name.prefix(20))
        presets[p] = preset
        touched["name\(p)"] = Date()
        write("name\(p)", delay: 0) { try $0.setEQPresetName(p, preset.name) }
        io.async { self.sentEQ[p]?.name = preset.name }
    }

    /// Sustituye un preset entero (importar fichero o preset de fábrica).
    func load(_ preset: EQPreset, into p: Int, note: String? = nil, undo: String = "«Volver a lo guardado» lo deshace.") {
        var np = preset
        np.index = p
        np.name = String(np.name.prefix(20))
        presets[p] = np
        touched["name\(p)"] = Date()
        pushEQ(np)
        write("name\(p)", delay: 0) { try $0.setEQPresetName(p, np.name) }
        io.async { self.sentEQ[p]?.name = np.name }
        say("«\(np.name)» cargado en el preset \(p). \(note.map { $0 + " " } ?? "")Sin guardar: \(undo)")
    }

    private func pushEQ(_ preset: EQPreset) {
        let p = preset.index
        write("eq\(p)") { [self] d in
            let old = io_sent(p)
            if old?.bands.map(\.gain) != preset.bands.map(\.gain) { try d.setEQGains(p, preset.bands.map(\.gain)) }
            for (i, b) in preset.bands.enumerated() where old == nil || old!.bands[i].frequency != b.frequency || old!.bands[i].bandwidth != b.bandwidth {
                try d.setEQFrequencyAndBandwidth(p, band: i + 1, frequency: b.frequency, bandwidth: b.bandwidth)
            }
            io_setSent(p, preset)
        }
    }

    // `write` ya corre en io; estos dos solo documentan que sentEQ vive ahí.
    private func io_sent(_ p: Int) -> EQPreset? { sentEQ[p] }
    private func io_setSent(_ p: Int, _ v: EQPreset) { sentEQ[p] = v }

    /// Vuelve el preset a lo que la base tiene guardado (descarta los cambios activos).
    func revert(_ p: Int) {
        touched["eq\(p)"] = Date(); touched["name\(p)"] = Date()
        io.async { [self] in
            guard let d = connect() else { return }
            do {
                let saved = try d.savedEQPreset(p)
                try d.setEQPreset(saved)
                sentEQ[p] = saved
                post { self.presets[p] = saved; self.say("«\(saved.name)» vuelto a lo guardado") }
            } catch { handle(error) }
        }
    }

    func saveToBase() {
        guard confirmSaveWithAuditions() else { return }
        io.async { [self] in
            guard let d = connect() else { return }
            do {
                try d.saveValues()
                var names: [Int: String] = [:]
                for p in A50Device.eqPresets { if let n = try soft({ try d.eqPresetName(p, saved: true) }) { names[p] = n } }
                post {
                    if names.count == A50Device.eqPresets.count { self.savedNames = names }
                    self.say("Guardado en la base")
                }
            } catch { handle(error) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { say("No se pudo cambiar el inicio de sesión: \(error.localizedDescription)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Autotest (`A50Control --autotest <informe.txt>`)

extension A50Model {
    static var selfTestPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--autotest"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Ejerce el camino interfaz → base → lectura con el preset 2, el balance, el sidetone y el
    /// preset activo contra el aparato real, y lo deja todo como estaba. Escribe el informe y sale.
    func runSelfTest(report path: String) {
        var log: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log.append("\(ok ? "OK   " : "FALLA") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func finish() {
            log.append(log.contains { $0.hasPrefix("FALLA") } ? "RESULTADO: FALLA" : "RESULTADO: OK")
            try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        var tries = 0
        func start() {
            guard link == .connected, let orig = presets[2], let orig1 = presets[1], let orig3 = presets[3], savedNames.count == 3 else {
                tries += 1
                if tries > 40 { check("conexión", false, "no leyó los presets en 12 s"); finish(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: start)
                return
            }
            let origBalance = balance, origSidetone = sidetone, origPreset = activePreset

            // Fase 1: cambios (con una ráfaga de 15 ediciones seguidas que debe agruparse).
            editBand(2, 1) { $0.gain = orig.bands[1].gain == 7 ? 6 : orig.bands[1].gain + 1 }
            editBand(2, 2) { $0.frequency = orig.bands[2].frequency + 100 }
            editBand(2, 3) { $0.bandwidth = 2048 }
            for g in EQBand.minGain...EQBand.maxGain { editBand(2, 4) { $0.gain = g } }
            rename(2, "TEST")
            setBalance(70)
            setSidetone(60)
            setPreset(origPreset == 1 ? 3 : 1)
            let expected = presets[2]!
            let wantedPreset = origPreset == 1 ? 3 : 1

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.io.async {
                    do {
                        let d = self.device!
                        let got = try d.eqPreset(2)
                        check("EQ editado llega a la base", got == expected,
                              "ganancias \(got.bands.map(\.gain)) · freq banda 3 \(got.bands[2].frequency) · nombre «\(got.name)»")
                        check("ráfaga agrupada: queda el último valor", got.bands[4].gain == EQBand.maxGain)
                        check("balance 70 %", try d.defaultBalance() == 179)
                        check("sidetone 60 %", try d.slider(.sideTone) == 60)
                        check("preset activo cambia", try d.activeEQPreset() == wantedPreset)
                    } catch { check("lectura fase 1", false, "\(error)") }

                    // Fase 2: dejarlo todo como estaba.
                    let phase2 = {
                        self.revert(2)
                        self.setBalance(origBalance)
                        self.setSidetone(origSidetone)
                        self.setPreset(origPreset)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.io.async {
                                do {
                                    let d = self.device!
                                    check("«volver a lo guardado» restaura el preset", try d.eqPreset(2) == orig)
                                    check("balance restaurado", try d.defaultBalance() == Int((origBalance / 100 * 255).rounded()))
                                    check("sidetone restaurado", try d.slider(.sideTone) == Int(origSidetone))
                                    check("preset activo restaurado", try d.activeEQPreset() == origPreset)
                                    // Una lectura que la base rechaza (como con los auriculares apagados) no debe tumbar el sondeo.
                                    let rejected: [UInt8]? = try self.soft { try d.raw(0xFE) }
                                    check("lectura rechazada por la base → nil, sin lanzar", rejected == nil)
                                    check("la base responde con normalidad tras el rechazo", (try? d.batteryStatus()) != nil)
                                } catch { check("lectura fase 2", false, "\(error)") }
                                DispatchQueue.main.async(execute: finish)
                            }
                        }
                    }

                    // Fase 1d: puerto de stream (con silenciar/reactivar), apagado automático y brillo, por el camino de la interfaz.
                    let phase1d = {
                        let chat = Slider.streamPortMixChat
                        let origChat = self.stream[chat] ?? 0, origShutoff = self.autoShutoff, origBright = self.brightness
                        let wantChat = origChat == 40 ? 41.0 : 40.0, wantShutoff = origShutoff == 20 ? 25 : 20, wantBright = origBright == 50 ? 55.0 : 50.0
                        self.setStream(chat, wantChat)
                        self.setAutoShutoff(wantShutoff)
                        self.setBrightness(wantBright)
                        func read(_ then: @escaping (A50Device) throws -> Void) {
                            self.io.async {
                                do { try then(self.device!) } catch { check("lectura fase 1d", false, "\(error)") }
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            read { d in
                                check("stream: el nivel del chat llega a la base", try d.slider(chat) == Int(wantChat))
                                check("apagado automático llega a la base", try d.autoShutoffMinutes() == wantShutoff)
                                check("brillo llega a la base", try d.brightness() == Int(wantBright))
                                DispatchQueue.main.async {
                                    self.toggleStreamMute(chat)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        read { d in
                                            check("silenciar el chat de stream deja el nivel en 0", try d.slider(chat) == 0)
                                            DispatchQueue.main.async {
                                                self.toggleStreamMute(chat)
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                                    read { d in
                                                        check("reactivarlo recupera el nivel anterior", try d.slider(chat) == Int(wantChat))
                                                        DispatchQueue.main.async {
                                                            self.setStream(chat, origChat)
                                                            self.setAutoShutoff(origShutoff)
                                                            self.setBrightness(origBright)
                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                                read { d in
                                                                    check("stream, apagado y brillo restaurados",
                                                                          try d.slider(chat) == Int(origChat) && d.autoShutoffMinutes() == origShutoff
                                                                            && d.brightness() == Int(origBright))
                                                                    DispatchQueue.main.async { phase2() }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Fase 1c: el desplegable del panel. Un predefinido suena en el hueco 3 sin cambiar los nombres que se
                    // enseñan; elegir un preset propio devuelve el hueco 3 a lo guardado. Nada se guarda en la base.
                    let phase1c = {
                        let e = EQLibrary.all[3]
                        self.choosePredefined(e)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            check("selector: suena el predefinido y los nombres no cambian",
                                  self.sounding?.entry.name == e.name && self.sounding?.slot == 3
                                    && self.slotLabel(1).hasSuffix(orig1.name) && self.slotLabel(3).hasSuffix(orig3.name),
                                  "\(self.slotLabel(1)) | \(self.slotLabel(2)) | \(self.slotLabel(3))")
                            self.io.async {
                                do {
                                    let d = self.device!
                                    check("predefinido escrito en el hueco 3 y activo", try d.eqPreset(3) == e.preset(index: 3) && d.activeEQPreset() == 3)
                                    check("el hueco 1 queda intacto", try d.eqPreset(1) == orig1)
                                } catch { check("lectura fase 1c", false, "\(error)") }
                                DispatchQueue.main.async {
                                    self.chooseSlot(origPreset)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        self.io.async {
                                            do {
                                                let d = self.device!
                                                check("elegir un preset propio devuelve el hueco 3 a lo guardado", try d.eqPreset(3) == orig3)
                                                check("y activa el preset elegido", try d.activeEQPreset() == origPreset)
                                            } catch { check("lectura fase 1c (vuelta)", false, "\(error)") }
                                            DispatchQueue.main.async {
                                                check("el selector deja de marcar un predefinido", self.sounding == nil)
                                                phase1d()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Fase 1b: un predefinido de la biblioteca, cargado por el mismo camino que el menú «Cargar…».
                    DispatchQueue.main.async {
                        let entry = EQLibrary.all[1]
                        self.load(entry.preset(index: 2), into: 2)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            self.io.async {
                                do {
                                    let got = try self.device!.eqPreset(2)
                                    check("predefinido «\(entry.name)» (menú «Cargar…») llega a la base", got == entry.preset(index: 2),
                                          "ganancias \(got.bands.map(\.gain)) · nombre «\(got.name)»")
                                } catch { check("lectura del predefinido", false, "\(error)") }
                                DispatchQueue.main.async(execute: phase1c)
                            }
                        }
                    }
                }
            }
        }
        start()
    }
}

extension A50Model {
    static var audioTestPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--autotest-audio"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Ejerce el enrutado de audio (encender → salida/entrada a la A50; apagar → devolverlas) y lo deja como estaba.
    func runAudioSelfTest(report path: String) {
        DispatchQueue.global().async {
            var log: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                log.append("\(ok ? "OK   " : "FALLA") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
            func current() -> (out: String?, inp: String?) { (AudioRouter.defaultName(input: false), AudioRouter.defaultName(input: true)) }

            let before = current()
            let target = AudioRouter.a50Names()
            log.append("antes: salida «\(before.out ?? "-")» · entrada «\(before.inp ?? "-")»")
            check("la A50 aparece como tarjetas de audio", target.output != nil && target.input != nil,
                  "salida «\(target.output ?? "-")» · entrada «\(target.input ?? "-")»")

            self.route(headsetOn: true)
            let during = current()
            check("al encender: la salida pasa a A50 Game", during.out == target.output, "«\(during.out ?? "-")»")
            check("al encender: la entrada pasa a A50 Voice", during.inp == target.input, "«\(during.inp ?? "-")»")

            self.route(headsetOn: false)
            let after = current()
            check("al apagar: la salida vuelve a la anterior", after.out == before.out, "«\(after.out ?? "-")»")
            check("al apagar: la entrada vuelve a la anterior", after.inp == before.inp, "«\(after.inp ?? "-")»")
            // Fase B: si la salida ya estaba en la A50, ese cambio no se ha ejercido; se prueba desde otra salida.
            if let other = AudioRouter.all().first(where: { $0.outputs > 0 && !$0.name.contains("A50") }), let origOut = before.out {
                AudioRouter.setDefault(name: other.name, input: false)
                check("(preparación) salida puesta en «\(other.name)»", current().out == other.name)
                self.route(headsetOn: true)
                check("al encender: la salida pasa de «\(other.name)» a A50 Game", current().out == target.output, "«\(current().out ?? "-")»")
                self.route(headsetOn: false)
                check("al apagar: la salida vuelve a «\(other.name)»", current().out == other.name, "«\(current().out ?? "-")»")
                AudioRouter.setDefault(name: origOut, input: false)
                check("salida original restaurada", current().out == origOut, "«\(current().out ?? "-")»")
            } else {
                log.append("AVISO: no hay otra salida de audio con la que ejercer el cambio de salida")
            }
            check("la entrada original queda como estaba", current().inp == before.inp, "«\(current().inp ?? "-")»")
            log.append(log.contains { $0.hasPrefix("FALLA") } ? "RESULTADO: FALLA" : "RESULTADO: OK")
            try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
