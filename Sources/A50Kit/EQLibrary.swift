import Foundation

/// Un preset de ecualizador listo para cargar en cualquiera de los 3 huecos de la base.
public struct EQLibraryEntry: Sendable {
    public let name: String      // ≤ 20 bytes: es lo que cabe en la base
    public let summary: String
    public let bands: [EQBand]

    public func preset(index: Int) -> EQPreset { EQPreset(index: index, name: name, bands: bands) }
}

/// Predefinidos de A50 Control, dentro de los rangos de la A50 Gen 4 (±7 dB, 80–15 000 Hz, ancho 0,1–3,0).
/// Son puntos de partida de manual (qué zona del espectro importa en cada uso), no mediciones de la A50:
/// se afinan con las bandas. Las bandas 1 y 5 son shelf; la 2, 3 y 4, campanas.
public enum EQLibrary {
    private static func shelf(_ gain: Int, _ hz: Int) -> EQBand { EQBand(gain: gain, frequency: hz, bandwidth: 0) }
    private static func peak(_ gain: Int, _ hz: Int, _ ratio: Double) -> EQBand {
        EQBand(gain: gain, frequency: hz, bandwidth: Int((ratio * 4096).rounded()))
    }

    /// Los de A50 Control, más abajo `astro`; `all` los junta (los de A50 Control van primero: las posiciones 1…8 no cambian).
    public static let own: [EQLibraryEntry] = [
        EQLibraryEntry(
            name: "Neutro",
            summary: "Sin colorear: referencia para comparar los demás.",
            bands: [shelf(0, 100), peak(0, 400, 1.0), peak(0, 1500, 1.0), peak(0, 5000, 1.0), shelf(0, 10_000)]),
        EQLibraryEntry(
            name: "Pasos FPS",
            summary: "Shooters: pasos y recargas más nítidos y menos retumbo.",
            bands: [shelf(-3, 120), peak(-2, 300, 0.8), peak(3, 2500, 1.0), peak(3, 5500, 0.8), shelf(1, 9000)]),
        EQLibraryEntry(
            name: "Graves potentes",
            summary: "Acción y explosiones: más pegada abajo sin enterrar las voces.",
            bands: [shelf(6, 110), peak(-1, 350, 1.0), peak(1, 2500, 1.0), peak(0, 5000, 1.0), shelf(1, 9000)]),
        EQLibraryEntry(
            name: "Cine",
            summary: "Películas y series: diálogos claros con cuerpo y algo de aire.",
            bands: [shelf(4, 100), peak(-2, 350, 0.9), peak(2, 2200, 1.0), peak(1, 5000, 1.0), shelf(3, 10_000)]),
        EQLibraryEntry(
            name: "Voz y charla",
            summary: "Podcasts, llamadas y chat de voz: voces nítidas y menos graves.",
            bands: [shelf(-5, 150), peak(-1, 350, 1.0), peak(3, 2000, 1.2), peak(2, 4000, 1.0), shelf(-1, 10_000)]),
        EQLibraryEntry(
            name: "Música",
            summary: "Curva en V suave: graves y brillos, medios algo hundidos.",
            bands: [shelf(3, 90), peak(-2, 600, 1.2), peak(1, 2500, 1.0), peak(2, 6000, 1.0), shelf(3, 10_000)]),
        EQLibraryEntry(
            name: "Volumen bajo",
            summary: "Escucha tranquila: compensa los graves y agudos que el oído pierde a poco volumen.",
            bands: [shelf(5, 100), peak(0, 500, 1.0), peak(1, 2000, 1.0), peak(1, 4000, 1.0), shelf(4, 9000)]),
        EQLibraryEntry(
            name: "Sesión larga",
            summary: "Sin fatiga: suaviza la aspereza de 3–7 kHz y el exceso de agudos.",
            bands: [shelf(1, 100), peak(0, 500, 1.0), peak(-2, 3500, 1.0), peak(-3, 6500, 0.9), shelf(-2, 10_000)]),
    ]

    /// Los 5 presets que trae de serie el Command Center para la A50 Gen 4 (copiados de su biblioteca el 2-11-2026).
    /// Los de la base del usuario con el mismo nombre pueden diferir: él los edita.
    public static let astro: [EQLibraryEntry] = [
        EQLibraryEntry(
            name: "ASTRO (fábrica)",
            summary: "De la biblioteca que trae el Command Center de Astro: «ASTRO».",
            bands: [shelf(6, 90), peak(-5, 406, 2), peak(0, 783, 2), peak(7, 4001, 2), shelf(7, 7001)]),
        EQLibraryEntry(
            name: "PRO (fábrica)",
            summary: "De la biblioteca que trae el Command Center de Astro: «PRO».",
            bands: [shelf(5, 95), peak(-2, 406, 2), peak(-1, 783, 2), peak(7, 3901, 0.5), shelf(1, 6339)]),
        EQLibraryEntry(
            name: "STUDIO (fábrica)",
            summary: "De la biblioteca que trae el Command Center de Astro: «STUDIO».",
            bands: [shelf(0, 95), peak(0, 419, 1), peak(0, 783, 2), peak(5, 3499, 1), shelf(7, 6100)]),
        EQLibraryEntry(
            name: "MEDIA (fábrica)",
            summary: "De la biblioteca que trae el Command Center de Astro: «MEDIA».",
            bands: [shelf(0, 95), peak(-3, 406, 2), peak(0, 783, 2), peak(2, 3901, 1.7), shelf(4, 6339)]),
        EQLibraryEntry(
            name: "A50 MOD KIT",
            summary: "De la biblioteca que trae el Command Center de Astro: «A50 MOD KIT».",
            bands: [shelf(-5, 200), peak(-7, 325, 1.7), peak(5, 2753, 2), peak(-7, 6691, 0.5), shelf(5, 11002)]),
    ]

    public static let all: [EQLibraryEntry] = own + astro

    /// Por posición (1…n) o por nombre, sin mayúsculas ni tildes.
    public static func find(_ key: String) -> EQLibraryEntry? {
        if let n = Int(key) { return all.indices.contains(n - 1) ? all[n - 1] : nil }
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return all.first { fold($0.name) == fold(key) }
    }
}
