import A50Kit
import SwiftUI
import UniformTypeIdentifiers

struct EQEditorView: View {
    @EnvironmentObject var m: A50Model
    @State private var nameDraft = ""
    @State private var nameFor = 0

    private static let bandNames = ["Graves", "Medio-graves", "Medios", "Medio-agudos", "Agudos"]
    private static let astroEQ = UTType(filenameExtension: "astroeq") ?? .plainText

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: Binding(get: { m.activePreset }, set: { m.setPreset($0) })) {
                ForEach(A50Device.eqPresets, id: \.self) { Text("\($0) · \(m.presets[$0]?.name ?? "—")").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if let preset = m.presets[m.activePreset] {
                HStack {
                    Text("Nombre").font(.callout)
                    TextField("Nombre", text: $nameDraft)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit { m.rename(preset.index, nameDraft) }
                    Spacer()
                    Text("Lo que editas suena al instante en los auriculares.").font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { sync(preset) }
                .onChange(of: m.activePreset) { if let p = m.presets[m.activePreset] { sync(p) } }

                EQCurve(bands: preset.bands).frame(height: 190)

                VStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in bandRow(preset, i) }
                }
                actions(preset)
            } else {
                Text(m.link == .connected ? "Leyendo presets…" : "Conecta la base A50.").foregroundStyle(.secondary)
            }
            if let n = m.notice { Text(n).font(.caption).foregroundStyle(.blue) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)  // el hueco sobrante, abajo y no arriba
        .frame(minWidth: 780, minHeight: 600)
    }

    private func sync(_ p: EQPreset) { nameDraft = p.name; nameFor = p.index }

    // MARK: Una banda

    private func bandRow(_ p: EQPreset, _ i: Int) -> some View {
        let band = p.bands[i]
        let shelf = i == 0 || i == 4
        return HStack(spacing: 10) {
            Text(Self.bandNames[i] + (shelf ? " ◢" : "")).font(.callout).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { Double(band.gain) }, set: { v in m.editBand(p.index, i) { $0.gain = Int(v.rounded()) } }),
                   in: Double(EQBand.minGain)...Double(EQBand.maxGain), step: 1)
                .frame(width: 150)
            Text(String(format: "%+d dB", band.gain)).font(.callout.monospacedDigit()).frame(width: 54, alignment: .trailing)

            Slider(value: Binding(get: { log10(Double(band.frequency)) },
                                  set: { v in m.editBand(p.index, i) { $0.frequency = Int(pow(10, v).rounded()) } }),
                   in: log10(Double(EQBand.minFrequency))...log10(Double(EQBand.maxFrequency)))
                .frame(width: 140)
            Text(freqLabel(band.frequency)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)

            if shelf {
                Text("shelf").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            } else {
                Slider(value: Binding(get: { log10(band.bandwidthRatio) },
                                      set: { v in m.editBand(p.index, i) { $0.bandwidth = Int((pow(10, v) * 4096).rounded()) } }),
                       in: log10(0.1)...log10(3.0))
                    .frame(width: 70)
                Text(String(format: "Q×%.2f", band.bandwidthRatio)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func freqLabel(_ f: Int) -> String { f >= 1000 ? String(format: "%.2f kHz", Double(f) / 1000) : "\(f) Hz" }

    // MARK: Acciones

    private func actions(_ p: EQPreset) -> some View {
        HStack {
            Menu("Cargar…") {
                Button("Desde un fichero .astroeq…") { importFile(into: p.index) }
                Divider()
                Text("Predefinidos de A50 Control")
                ForEach(EQLibrary.own, id: \.name) { e in
                    Button(e.name) { m.load(e.preset(index: p.index), into: p.index, note: e.summary) }
                        .help(e.summary)
                }
                Divider()
                Text("De fábrica de Astro")
                ForEach(EQLibrary.astro, id: \.name) { e in
                    Button(e.name) { m.load(e.preset(index: p.index), into: p.index, note: e.summary) }
                        .help(e.summary)
                }
            }.frame(width: 110)
            Button("Exportar…") { export(p) }
            Spacer()
            Button("Volver a lo guardado") { m.revert(p.index) }
                .help("Descarta los cambios de este preset y recupera lo que tiene guardado la base.")
            Button("Guardar en la base") { m.saveToBase() }.keyboardShortcut("s")
        }
    }

    private func importFile(into slot: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.astroEQ, .plainText]
        panel.message = "Elige un preset .astroeq"
        if panel.runModal() == .OK, let url = panel.url { importURL(url, into: slot) }
    }

    private func importURL(_ url: URL, into slot: Int) {
        do {
            let parsed = try AstroEQFile.parse(String(contentsOf: url, encoding: .utf8), index: slot)
            m.load(parsed.preset, into: slot)
            if !parsed.warnings.isEmpty { m.say("Recortado al rango de la A50: " + parsed.warnings.joined(separator: "; ")) }
        } catch { m.say("No se pudo leer el preset: \(error)") }
    }

    private func export(_ p: EQPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.astroEQ]
        panel.nameFieldStringValue = "\(p.name).astroeq"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AstroEQFile.serialize(p).write(to: url, atomically: true, encoding: .utf8)
            m.say("Exportado a \(url.lastPathComponent)")
        } catch { m.say("No se pudo guardar: \(error.localizedDescription)") }
    }
}

/// Respuesta en frecuencia aproximada (20 Hz–20 kHz, ±12 dB).
struct EQCurve: View {
    let bands: [EQBand]
    private let fMin = 20.0, fMax = 20_000.0, dbMax = 12.0

    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / fMin) / log10(fMax / fMin)) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(db / dbMax) * size.height / 2 }

            for db in stride(from: -12.0, through: 12.0, by: 6) {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y(db))); line.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.6 : 0.2)), lineWidth: db == 0 ? 1 : 0.5)
                ctx.draw(Text("\(Int(db))").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 12, y: y(db) - 7))
            }
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                var line = Path(); line.move(to: CGPoint(x: x(f), y: 0)); line.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x(f) + 10, y: size.height - 8))
            }

            var curve = Path()
            let steps = 240
            for s in 0...steps {
                let f = fMin * pow(fMax / fMin, Double(s) / Double(steps))
                let db = max(-dbMax, min(dbMax, EQMath.responseDB(bands, at: f)))
                let p = CGPoint(x: x(f), y: y(db))
                s == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2.5)

            for (i, b) in bands.enumerated() {
                let p = CGPoint(x: x(Double(b.frequency)), y: y(max(-dbMax, min(dbMax, EQMath.responseDB(bands, at: Double(b.frequency))))))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.accentColor))
                ctx.draw(Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.white), at: p)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .help("Curva aproximada: el firmware no documenta su filtro exacto.")
    }
}
