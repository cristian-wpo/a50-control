import A50Kit
import SwiftUI

struct MenuLabel: View {
    @EnvironmentObject var m: A50Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: m.link == .connected && (m.headset?.isOn ?? false) ? "headphones" : "headphones.slash")
            if m.link == .connected, let b = m.battery, m.headset?.isOn ?? false {
                Text("\(b.percent)%")
            }
        }
        .onAppear {
            AppWindows.opener = { openWindow(id: $0) }
            if m.openEQOnLaunch { AppWindows.show("eq") }
            if m.openPanelOnLaunch { AppWindows.show("panel") }
            if let path = A50Model.selfTestPath { m.runSelfTest(report: path) }
            if let path = A50Model.audioTestPath { m.runAudioSelfTest(report: path) }
            if let path = AppWindows.testPath { AppWindows.runSelfTest(report: path) }
            if let path = Diagnostics.argument("--autotest-diag") { Diagnostics.runSelfTest(report: path) }
            if let path = Diagnostics.argument("--autotest-micro") { m.diagnostics.runMicSelfTest(report: path) }
            if let dir = Capture.directory {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Capture.run(into: dir) }
            }
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var m: A50Model
    /// `true` cuando es la ventana normal y no el desplegable de la barra de menús.
    var inWindow = false
    @State private var diagnosticsOpen = CommandLine.arguments.contains("--diagnostico-abierto") || CommandLine.arguments.contains("--todo-abierto")
    @State private var streamOpen = CommandLine.arguments.contains("--todo-abierto")
    @State private var baseOpen = CommandLine.arguments.contains("--todo-abierto")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch m.link {
            case .connected: controls
            case .searching: Text("Buscando la base…").foregroundStyle(.secondary)
            case .noBase:
                Label("Conecta la base A50 por USB", systemImage: "cable.connector.slash").foregroundStyle(.secondary)
            case .error(let e):
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Cabecera y batería

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let logo = NSImage(named: "AppIcon") {
                    Image(nsImage: logo).resizable().frame(width: 36, height: 36)
                } else {
                    Image(systemName: "headphones").font(.title2)   // sin paquete .app (swift run) no hay icono que cargar
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("ASTRO A50 Gen 4").font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !inWindow {
                    Button { AppWindows.show("panel") } label: { Image(systemName: "macwindow") }
                        .buttonStyle(.borderless).help("Abrir en una ventana")
                }
            }
            if m.link == .connected, let b = m.battery {
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.25))
                            Capsule().fill(batteryColor(b.percent)).frame(width: g.size.width * CGFloat(b.percent) / 100)
                        }
                    }.frame(height: 8)
                    Text("\(b.percent) %").monospacedDigit().font(.callout)
                    if b.isCharging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                }
            }
        }
    }

    private var statusText: String {
        guard m.link == .connected, let h = m.headset else { return "Sin conexión" }
        switch (h.isOn, h.isDocked) {
        case (true, true): return "Encendidos · en la base"
        case (true, false): return "Encendidos"
        case (false, true): return "Apagados · en la base"
        default: return "Apagados"
        }
    }

    private func batteryColor(_ p: Int) -> Color { p <= 15 ? .red : p <= 35 ? .orange : .green }

    // MARK: Controles

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ecualizador").font(.subheadline.weight(.semibold))
                // Tus 3 presets, siempre con su número y su nombre guardado. Sin marcar ninguno = suena un predefinido.
                Picker("", selection: Binding<Int?>(get: { m.sounding == nil ? m.activePreset : nil },
                                                    set: { if let n = $0 { m.chooseSlot(n) } })) {
                    ForEach(A50Device.eqPresets, id: \.self) { Text(m.slotLabel($0)).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack {
                    Button("Editar ecualizador…") { AppWindows.show("eq") }.controlSize(.small)
                    Menu {
                        Section("De A50 Control") { ForEach(EQLibrary.own, id: \.name) { predefined($0) } }
                        Section("De fábrica de Astro") { ForEach(EQLibrary.astro, id: \.name) { predefined($0) } }
                    } label: {
                        if let s = m.sounding { Label(s.entry.name, systemImage: "waveform") } else { Text("Predefinidos") }
                    }
                    .controlSize(.small).fixedSize()
                    .help("Predefinidos: suenan en el hueco 3 como prueba y no tocan tus presets guardados.")
                }
                if let s = m.sounding {
                    Text("Suena el predefinido «\(s.entry.name)» (hueco \(s.slot), sin guardar). Pulsa uno de tus 3 presets para volver a ellos.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Mezcla").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(balanceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { m.balance }, set: { m.setBalance($0.rounded()) }), in: 0...100) {
                    EmptyView()
                } minimumValueLabel: { Text("Juego").font(.caption) } maximumValueLabel: { Text("Chat").font(.caption) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Micrófono").font(.subheadline.weight(.semibold))
                percentSlider("Nivel", value: m.mic, set: m.setMic)
                percentSlider("Retorno de voz", value: m.sidetone, set: m.setSidetone)
                HStack {
                    Text("Puerta de ruido").font(.callout)
                    Spacer()
                    Picker("", selection: Binding(get: { m.gate }, set: { m.setGate($0) })) {
                        ForEach(NoiseGateMode.allCases, id: \.self) { Text(gateName($0)).tag($0) }
                    }.labelsHidden().frame(width: 130)
                }
                HStack {
                    Text("EQ del micro").font(.callout)
                    Spacer()
                    Picker("", selection: Binding(get: { m.micEQ }, set: { m.setMicEQ($0) })) {
                        ForEach(0...2, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }
            }

            percentSlider("Volumen de avisos", value: m.alert, set: m.setAlert)

            DisclosureGroup("Puerto de stream (jack trasero)", isExpanded: $streamOpen) { streamSection }
                .font(.callout)

            DisclosureGroup("Base y energía", isExpanded: $baseOpen) { baseSection }
                .font(.callout)

            DisclosureGroup("Diagnóstico: voz robótica, cortes, USB", isExpanded: $diagnosticsOpen) { DiagnosticsSection() }
                .font(.callout)
        }
    }

    private func predefined(_ e: EQLibraryEntry) -> some View {
        Button { m.choosePredefined(e) } label: {
            if m.sounding?.entry.name == e.name { Label(e.name, systemImage: "checkmark") } else { Text(e.name) }
        }.help(e.summary)
    }

    private static let streamRows: [(A50Kit.Slider, String)] = [
        (.streamPortMixMic, "Micrófono"), (.streamPortMixChat, "Chat"), (.streamPortMixGame, "Juego"), (.streamPortMixAux, "Aux"),
    ]

    /// Mezcla de la salida analógica trasera de la base (la que va a una capturadora o a unos altavoces).
    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Qué mezcla sale por el jack trasero de la base (streaming, capturadora). El altavoz silencia el canal y lo recuerda.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.streamRows, id: \.0) { k, label in
                let v = m.stream[k] ?? 0
                HStack(spacing: 6) {
                    Button { m.toggleStreamMute(k) } label: { Image(systemName: v > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill").frame(width: 18) }
                        .buttonStyle(.borderless).help(v > 0 ? "Silenciar \(label)" : "Reactivar \(label)")
                    Text(label).font(.callout).frame(width: 74, alignment: .leading)
                    Slider(value: Binding(get: { v }, set: { m.setStream(k, $0.rounded()) }), in: 0...100)
                    Text("\(Int(v))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.top, 4)
    }

    private var baseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apagado automático").font(.callout)
                Spacer()
                Picker("", selection: Binding(get: { m.autoShutoff }, set: { m.setAutoShutoff($0) })) {
                    ForEach(Set(A50Device.autoShutoffChoices + [m.autoShutoff]).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden().frame(width: 100)
            }
            Text("Minutos sin moverlos hasta que los auriculares se apagan solos.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("Brillo de la base").font(.callout).frame(width: 120, alignment: .leading)
                let r = A50Device.brightnessRange
                Slider(value: Binding(get: { m.brightness }, set: { m.setBrightness($0.rounded()) }),
                       in: Double(r.lowerBound)...Double(r.upperBound))
                Text("\(Int(m.brightness))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.top, 4)
    }

    private func percentSlider(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0.rounded()) }), in: 0...100)
            Text("\(Int(value))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
    }

    private var balanceLabel: String {
        let chat = Int(m.balance.rounded())
        return chat == 50 ? "Equilibrada" : "\(100 - chat) % juego · \(chat) % chat"
    }

    private func gateName(_ g: NoiseGateMode) -> String {
        switch g {
        case .streaming: return "Streaming"
        case .night: return "Noche"
        case .home: return "Casa"
        case .tournament: return "Torneo"
        }
    }

    // MARK: Pie

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let n = m.notice { Text(n).font(.caption).foregroundStyle(.blue) }
            Toggle("Pasar el audio del Mac a la A50 al encenderla", isOn: $m.autoRoute).font(.callout)
            Toggle("Avisar con batería baja", isOn: $m.batteryAlerts).font(.callout)
            Toggle("Abrir al iniciar sesión", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) })).font(.callout)
            HStack {
                Button("Guardar en la base") { m.saveToBase() }
                    .help("Hace permanentes los cambios: sin esto se pierden al reiniciar la base.")
                    .disabled(m.link != .connected)
                Menu {
                    Button("Guardar perfil…") { m.saveProfile() }.disabled(m.link != .connected)
                    Button("Cargar perfil…") { m.loadProfile() }.disabled(m.link != .connected)
                    Divider()
                    Button("Informe de diagnóstico…") { m.exportReport() }
                } label: { Text("Perfil") }
                    .fixedSize()
                    .help("Guarda o carga TODA la configuración (presets, micrófono, stream, energía) y genera un informe de diagnóstico.")
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
            if !versions.isEmpty { Text("Firmware " + versions).font(.caption2).foregroundStyle(.tertiary) }
            if inWindow {
                Text("Si cierras esta ventana, A50 Control sigue en la barra de menús (icono de auriculares, arriba a la derecha). Para volver: ábrela otra vez desde Launchpad o Spotlight.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versions: String {
        [m.baseFW.isEmpty ? nil : "base \(m.baseFW)", m.headsetFW.isEmpty ? nil : "auriculares \(m.headsetFW)"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
