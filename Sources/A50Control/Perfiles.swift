import A50Kit
import AppKit
import UniformTypeIdentifiers

/// «Guardar perfil / Cargar perfil» e informe de diagnóstico: lo que el Command Center esconde en su rueda de ajustes.
extension A50Model {
    private static let profileType = UTType(filenameExtension: "a50perfil") ?? .plainText

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func askSaveURL(title: String, name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Guarda en un fichero TODO lo que la base tiene activo (3 presets, micrófono, puerto de stream, energía, brillo…).
    func saveProfile() {
        guard let url = askSaveURL(title: "Guardar perfil de la A50", name: "Perfil A50 \(Self.stamp()).a50perfil", type: Self.profileType) else { return }
        io.async { [self] in
            guard let d = connect() else { return }
            do {
                let text = try A50Profile.read(from: d).text()
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    post { self.say("Perfil guardado: \(url.lastPathComponent)") }
                } catch {
                    post { self.alert("No se pudo escribir el fichero", error.localizedDescription) }
                }
            } catch { handle(error) }
        }
    }

    /// Carga un perfil en los valores ACTIVOS de la base. Para que sobreviva a un reinicio, «Guardar en la base».
    func loadProfile() {
        let panel = NSOpenPanel()
        panel.title = "Cargar perfil de la A50"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profile: A50Profile
        do { profile = try A50Profile(parsing: try String(contentsOf: url, encoding: .utf8)) } catch {
            alert("No se pudo cargar «\(url.lastPathComponent)»", "\(error). La base no se ha tocado.")
            return
        }
        io.async { [self] in
            guard let d = connect() else { return }
            do {
                try profile.apply(to: d)
                post {
                    self.say("Perfil «\(url.lastPathComponent)» cargado (sin guardar en la base)")
                    self.refresh(full: true)
                }
            } catch { handle(error) }
        }
    }

    /// Fichero de texto con todo lo que hace falta para diagnosticar un problema (equivalente al «informe TPS»).
    func exportReport() {
        guard let url = askSaveURL(title: "Informe de diagnóstico de la A50", name: "Informe A50 \(Self.stamp()).txt", type: .plainText) else { return }
        let usb = diagnostics.usb?.summary ?? "sin datos"
        let incidents = (try? String(contentsOf: diagnostics.logURL, encoding: .utf8))?
            .split(separator: "\n").suffix(60).joined(separator: "\n") ?? "(sin incidencias anotadas)"
        let audio = A50Audio.devices().map { a in
            "  \(a.name): \(Int(a.sampleRate)) Hz · entrada \(a.inputChannels) · salida \(a.outputChannels)"
        }.joined(separator: "\n")
        let state = "enlace \(link) · auriculares \(headset.map { "\($0.isOn ? "encendidos" : "apagados")\($0.isDocked ? ", en la base" : "")" } ?? "sin datos")"
            + (battery.map { " · batería \($0.percent) %\($0.isCharging ? " (cargando)" : "")" } ?? "")
        let fw = "base \(baseFW.isEmpty ? "?" : baseFW) · auriculares \(headsetFW.isEmpty ? "?" : headsetFW)"
        io.async { [self] in
            let profile: String
            if let d = connect(), let p = try? A50Profile.read(from: d) { profile = p.text() } else { profile = "(la base no contestó)" }
            let text = """
            Informe de A50 Control · \(Date())
            Mac: \(ProcessInfo.processInfo.operatingSystemVersionString)

            — Estado —
            \(state)
            Firmware: \(fw)

            — USB —
            \(usb)

            — Tarjetas de audio de la A50 —
            \(audio.isEmpty ? "  (no aparece ninguna)" : audio)

            — Configuración activa en la base —
            \(profile)

            — Últimas incidencias (cortes de USB/enlace y marcas «suena robótico») —
            \(incidents)

            Límite: la base no expone la calidad del enlace de radio; este informe no puede medir interferencias.
            """
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                post { self.say("Informe guardado: \(url.lastPathComponent)") }
            } catch {
                post { self.alert("No se pudo escribir el informe", error.localizedDescription) }
            }
        }
    }
}
