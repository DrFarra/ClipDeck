import SwiftUI

extension Color {
    /// Crea un color desde "#RRGGBB".
    init(hex: String) {
        var value: UInt64 = 0
        var hexString = hex
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        Scanner(string: hexString).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Color adaptativo claro/oscuro.
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
    }

    /// Luminancia aproximada para elegir texto claro u oscuro sobre este fondo.
    static func isLightHex(_ hex: String) -> Bool {
        var value: UInt64 = 0
        var hexString = hex
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        Scanner(string: hexString).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}

enum Theme {
    static let background = Color(light: "#F3F3FA", dark: "#151517")
    static let card = Color(light: "#FFFFFF", dark: "#242429")
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let accent = Color(hex: "#4E7CF6")

    static let pinboardColors = ["#F0453B", "#F5A623", "#38B44A", "#4E7CF6", "#8E5CF6", "#EC5CA8", "#F07830"]

    static let cardCornerRadius: CGFloat = 18
    static let capsuleCornerRadius: CGFloat = 24
}

/// Liquid Glass (iOS 26+) con degradado elegante a material en versiones anteriores.
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
