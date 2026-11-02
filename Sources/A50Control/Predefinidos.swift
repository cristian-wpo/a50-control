import A50Kit
import AppKit

/// Cómo conviven los predefinidos con los 3 presets del usuario en el desplegable del panel.
///
/// Un predefinido suena en el hueco 3 (`scratchSlot`) como PRUEBA: el selector sigue mostrando los tres presets con su
/// número y su nombre GUARDADO, y al elegir uno propio el hueco vuelve a lo que la base tiene guardado. Nada se
/// sustituye en la base sin que `saveToBase` lo pregunte.
extension A50Model {
    /// El hueco 3 es el «STUDIO» plano de fábrica: el que menos se pierde al usarlo de pizarra.
    static let scratchSlot = 3

    /// Un preset activo es «una prueba» si es exactamente un predefinido y la base no lo tiene guardado en ese hueco.
    static func audition(of preset: EQPreset?, savedName: String?) -> EQLibraryEntry? {
        guard let preset,
              let entry = EQLibrary.all.first(where: { $0.name == preset.name && $0.bands == preset.bands }) else { return nil }
        return savedName == entry.name ? nil : entry
    }

    func audition(in slot: Int) -> EQLibraryEntry? { Self.audition(of: presets[slot], savedName: savedNames[slot]) }

    var auditions: [(slot: Int, entry: EQLibraryEntry)] {
        A50Device.eqPresets.compactMap { s in audition(in: s).map { (slot: s, entry: $0) } }
    }

    /// El predefinido que suena ahora (el del hueco activo), si lo hay.
    var sounding: (slot: Int, entry: EQLibraryEntry)? {
        audition(in: activePreset).map { (slot: activePreset, entry: $0) }
    }

    /// «3 · STUDIO»: con una prueba en el hueco se enseña el nombre guardado, no el del predefinido.
    func slotLabel(_ n: Int) -> String {
        let name = audition(in: n) != nil ? savedNames[n] : presets[n]?.name
        return "\(n) · \(name ?? "Preset \(n)")"
    }

    func choosePredefined(_ e: EQLibraryEntry) {
        let s = Self.scratchSlot
        load(e.preset(index: s), into: s, note: e.summary, undo: "Elige uno de tus presets para volver a ellos.")
        setPreset(s)
    }

    /// Elige uno de los 3 presets propios; cualquier prueba pendiente vuelve a lo guardado.
    func chooseSlot(_ n: Int) {
        for a in auditions { revert(a.slot) }
        setPreset(n)
    }

    /// Antes de guardar: si hay predefinidos sin guardar en los huecos, pregunta qué hacer. `false` = cancelado.
    func confirmSaveWithAuditions() -> Bool {
        let pending = auditions
        guard !pending.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Hay predefinidos sonando sin guardar"
        alert.informativeText = pending
            .map { "Hueco \($0.slot): «\($0.entry.name)» sustituiría a «\(savedNames[$0.slot] ?? "Preset \($0.slot)")»" }
            .joined(separator: "\n") + "\n\n¿Qué guardo?"
        alert.addButton(withTitle: "Guardar sin los predefinidos")
        alert.addButton(withTitle: "Guardarlos también")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            pending.forEach { revert($0.slot) }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}
