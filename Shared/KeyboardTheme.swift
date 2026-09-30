import UIKit

/// Un tema del teclado: fondo, teclas, textos y globos.
///
/// Vive en Shared para que la app dibuje la vista previa con los mismos
/// colores que pinta la extensión. Los temas que siguen el modo claro/oscuro
/// del sistema usan colores dinámicos; los demás fijan su apariencia con
/// `appearance`, para que los textos del sistema (etiquetas, SwiftUI) sigan
/// siendo legibles sobre su fondo.
struct KeyboardTheme: Identifiable {
    enum Appearance { case system, light, dark }

    enum Backdrop {
        /// El gris de teclado de siempre: un `UIInputView` con estilo `.keyboard`.
        case keyboard
        /// Transparente: se ve el cristal del sistema (iOS 26).
        case clear
        case solid(UIColor)
        /// De arriba abajo.
        case gradient(UIColor, UIColor)
    }

    enum Family: String, CaseIterable, Identifiable {
        case essentials = "Esenciales"
        case dark = "Oscuros"
        case light = "Claros"
        case accessibility = "Accesibilidad"

        var id: String { rawValue }
    }

    let id: String
    let name: String
    /// Para quién es, en una línea.
    let audience: String
    let family: Family
    let appearance: Appearance
    let backdrop: Backdrop

    let letter: UIColor
    let letterPressed: UIColor
    let function: UIColor
    let functionPressed: UIColor
    let text: UIColor
    let secondaryText: UIColor
    /// Opción marcada en los globos, iconos activos y retorno con nombre.
    let accent: UIColor
    let accentText: UIColor
    let shiftOn: UIColor
    let shiftOnText: UIColor
    /// Globo de la tecla pulsada.
    let popup: UIColor
    /// Globos de acentos y de tonos de piel, avisos.
    let menu: UIColor

    /// Retorno con nombre (Buscar, Enviar…) en el color de acento.
    var accentReturn = false
    var keyShadow: UIColor? = nil
    var keyBorder: UIColor? = nil
    var separator: UIColor = .separator
    var cornerRadius: CGFloat = 8
    var boldKeys = false
}

// MARK: - Catálogo

extension KeyboardTheme {
    static let defaultID = "classic"

    static let all: [KeyboardTheme] = [
        classic, glass, slate,
        graphite, midnight, oled, ocean,
        sand, sage, lavender,
        contrast
    ]

    /// El tema guardado, o el clásico si ya no existe.
    static func named(_ id: String) -> KeyboardTheme {
        all.first { $0.id == id } ?? classic
    }

    /// El de siempre de ClipDeck: son los colores de antes de que hubiera temas.
    static let classic = KeyboardTheme(
        id: "classic", name: "Clásico",
        audience: "El de siempre: gris neutro para todos los días",
        family: .essentials, appearance: .system, backdrop: .keyboard,
        letter: .secondarySystemBackground, letterPressed: .systemGray2,
        function: .systemGray4, functionPressed: .systemGray2,
        text: .label, secondaryText: .secondaryLabel,
        accent: .systemBlue, accentText: .white,
        shiftOn: .systemGray, shiftOnText: .white,
        popup: .systemGray3, menu: .systemGray4)

    static let glass = KeyboardTheme(
        id: "glass", name: "Cristal",
        audience: "Como el teclado de iOS 26: teclas blancas sobre el cristal",
        family: .essentials, appearance: .system, backdrop: .clear,
        letter: adaptive(.white, gray(0.42)), letterPressed: adaptive(rgb(0xABB3BA), gray(0.27)),
        function: adaptive(rgb(0xABB3BA), gray(0.27)), functionPressed: adaptive(.white, gray(0.42)),
        text: .label, secondaryText: .secondaryLabel,
        accent: .systemBlue, accentText: .white,
        shiftOn: .white, shiftOnText: .black,
        popup: adaptive(.white, gray(0.42)), menu: adaptive(.white, gray(0.42)),
        accentReturn: true,
        keyShadow: adaptive(rgb(0x898A8E), UIColor(white: 0, alpha: 0.4)))

    static let slate = KeyboardTheme(
        id: "slate", name: "Pizarra",
        audience: "Sobrio y profesional, en claro y en oscuro",
        family: .essentials, appearance: .system,
        backdrop: .solid(adaptive(rgb(0xE3E7EC), rgb(0x15181D))),
        letter: adaptive(.white, rgb(0x2B3039)), letterPressed: adaptive(rgb(0xC6CDD6), rgb(0x3B424D)),
        function: adaptive(rgb(0xC6CDD6), rgb(0x1F242B)), functionPressed: adaptive(.white, rgb(0x2B3039)),
        text: adaptive(rgb(0x1B2230), rgb(0xEEF1F5)), secondaryText: adaptive(rgb(0x687181), rgb(0x8C95A3)),
        accent: adaptive(rgb(0x2F6FEB), rgb(0x5B8DEF)), accentText: .white,
        shiftOn: adaptive(rgb(0x1B2230), rgb(0xEEF1F5)), shiftOnText: adaptive(.white, rgb(0x15181D)),
        popup: adaptive(.white, rgb(0x353B45)), menu: adaptive(.white, rgb(0x353B45)),
        accentReturn: true,
        keyShadow: adaptive(rgb(0xA8B1BD), UIColor(white: 0, alpha: 0.5)),
        separator: adaptive(rgb(0xB9C1CC), rgb(0x333A44)),
        cornerRadius: 9)

    static let graphite = KeyboardTheme(
        id: "graphite", name: "Grafito",
        audience: "Oscuro y sobrio, con acento ámbar: para trabajar de noche",
        family: .dark, appearance: .dark, backdrop: .solid(rgb(0x17181B)),
        letter: rgb(0x2E2F33), letterPressed: rgb(0x46484E),
        function: rgb(0x232428), functionPressed: rgb(0x36383D),
        text: rgb(0xF2F2F5), secondaryText: rgb(0x9A9CA4),
        accent: rgb(0xFF9F0A), accentText: rgb(0x1A1A1A),
        shiftOn: rgb(0xF2F2F5), shiftOnText: rgb(0x17181B),
        popup: rgb(0x3A3B40), menu: rgb(0x3A3B40),
        accentReturn: true,
        keyShadow: UIColor(white: 0, alpha: 0.55),
        separator: rgb(0x3A3B40))

    static let midnight = KeyboardTheme(
        id: "midnight", name: "Medianoche",
        audience: "Azul noche profundo, descansa la vista",
        family: .dark, appearance: .dark, backdrop: .gradient(rgb(0x121C31), rgb(0x0A1120)),
        letter: rgb(0x1F2C47), letterPressed: rgb(0x2F4166),
        function: rgb(0x172239), functionPressed: rgb(0x25334F),
        text: rgb(0xE9EEF9), secondaryText: rgb(0x8FA0C2),
        accent: rgb(0x6C95FF), accentText: .white,
        shiftOn: rgb(0xE9EEF9), shiftOnText: rgb(0x121C31),
        popup: rgb(0x2A3A5C), menu: rgb(0x2A3A5C),
        accentReturn: true,
        keyShadow: UIColor(white: 0, alpha: 0.45),
        separator: rgb(0x2A3A5C),
        cornerRadius: 9)

    static let oled = KeyboardTheme(
        id: "oled", name: "Negro OLED",
        audience: "Negro puro: ahorra batería en pantallas OLED",
        family: .dark, appearance: .dark, backdrop: .solid(.black),
        letter: rgb(0x131313), letterPressed: rgb(0x2C2C2C),
        function: rgb(0x0A0A0A), functionPressed: rgb(0x1F1F1F),
        text: .white, secondaryText: rgb(0x8A8A8E),
        accent: rgb(0x0A84FF), accentText: .white,
        shiftOn: .white, shiftOnText: .black,
        popup: rgb(0x1C1C1E), menu: rgb(0x1C1C1E),
        keyBorder: rgb(0x262626),
        separator: rgb(0x262626))

    static let ocean = KeyboardTheme(
        id: "ocean", name: "Océano",
        audience: "Azul petróleo con turquesa: color sin estridencias",
        family: .dark, appearance: .dark, backdrop: .gradient(rgb(0x10343F), rgb(0x0A242D)),
        letter: rgb(0x1C4B5B), letterPressed: rgb(0x2A6376),
        function: rgb(0x153B48), functionPressed: rgb(0x1F5062),
        text: rgb(0xE6F4F7), secondaryText: rgb(0x8CB8C2),
        accent: rgb(0x2EC4B6), accentText: rgb(0x062A2F),
        shiftOn: rgb(0xE6F4F7), shiftOnText: rgb(0x10343F),
        popup: rgb(0x245868), menu: rgb(0x245868),
        accentReturn: true,
        keyShadow: UIColor(white: 0, alpha: 0.4),
        separator: rgb(0x245868),
        cornerRadius: 9)

    static let sand = KeyboardTheme(
        id: "sand", name: "Arena",
        audience: "Cálido como el papel: para leer y escribir mucho rato",
        family: .light, appearance: .light, backdrop: .solid(rgb(0xECE4D6)),
        letter: rgb(0xFBF7F0), letterPressed: rgb(0xD8CCB8),
        function: rgb(0xDCD0BD), functionPressed: rgb(0xFBF7F0),
        text: rgb(0x3B3127), secondaryText: rgb(0x8A7A66),
        accent: rgb(0xB8733A), accentText: .white,
        shiftOn: rgb(0x3B3127), shiftOnText: rgb(0xFBF7F0),
        popup: rgb(0xFFFDF8), menu: rgb(0xFFFDF8),
        accentReturn: true,
        keyShadow: rgb(0xC4B59E),
        separator: rgb(0xCDBFA9))

    static let sage = KeyboardTheme(
        id: "sage", name: "Salvia",
        audience: "Verde suave y natural, tranquilo y minimalista",
        family: .light, appearance: .light, backdrop: .solid(rgb(0xDDE5DA)),
        letter: rgb(0xF7FAF5), letterPressed: rgb(0xBFCDBB),
        function: rgb(0xC2D0BE), functionPressed: rgb(0xF7FAF5),
        text: rgb(0x273528), secondaryText: rgb(0x6C7F6C),
        accent: rgb(0x4E7F5A), accentText: .white,
        shiftOn: rgb(0x273528), shiftOnText: rgb(0xF7FAF5),
        popup: .white, menu: .white,
        accentReturn: true,
        keyShadow: rgb(0xAEBFAA),
        separator: rgb(0xB3C3AF),
        cornerRadius: 10)

    static let lavender = KeyboardTheme(
        id: "lavender", name: "Lavanda",
        audience: "Lila empolvado, delicado y creativo",
        family: .light, appearance: .light, backdrop: .gradient(rgb(0xEFE9F8), rgb(0xE4DCF2)),
        letter: rgb(0xFDFBFF), letterPressed: rgb(0xD3C7E9),
        function: rgb(0xD8CDEB), functionPressed: rgb(0xFDFBFF),
        text: rgb(0x362A4B), secondaryText: rgb(0x7C6D96),
        accent: rgb(0x8B5CF6), accentText: .white,
        shiftOn: rgb(0x362A4B), shiftOnText: rgb(0xFDFBFF),
        popup: .white, menu: .white,
        accentReturn: true,
        keyShadow: rgb(0xC3B6DC),
        separator: rgb(0xCBBFE0),
        cornerRadius: 10)

    static let contrast = KeyboardTheme(
        id: "contrast", name: "Alto contraste",
        audience: "Máxima legibilidad: blanco sobre negro y bordes marcados",
        family: .accessibility, appearance: .dark, backdrop: .solid(.black),
        letter: .black, letterPressed: rgb(0x3A3A3A),
        function: rgb(0x1C1C1C), functionPressed: rgb(0x3A3A3A),
        text: .white, secondaryText: .white,
        accent: rgb(0xFFD60A), accentText: .black,
        shiftOn: rgb(0xFFD60A), shiftOnText: .black,
        popup: rgb(0x1C1C1C), menu: rgb(0x1C1C1C),
        accentReturn: true,
        keyBorder: .white,
        separator: .white,
        cornerRadius: 6,
        boldKeys: true)
}

// MARK: - Vistas previas

extension KeyboardTheme {
    /// Colores del fondo para las miniaturas de la app, de arriba abajo. El
    /// gris de teclado y el cristal los pinta el sistema: aquí se imitan.
    var previewBackdrop: [UIColor] {
        switch backdrop {
        case .keyboard: return [Self.adaptive(Self.rgb(0xD1D4D9), Self.rgb(0x2C2C2E))]
        case .clear: return [Self.adaptive(Self.rgb(0xE8EAEE), Self.rgb(0x1E1E20))]
        case .solid(let color): return [color]
        case .gradient(let top, let bottom): return [top, bottom]
        }
    }
}

// MARK: - Colores

private extension KeyboardTheme {
    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    static func gray(_ white: CGFloat) -> UIColor {
        UIColor(white: white, alpha: 1)
    }

    static func adaptive(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}
