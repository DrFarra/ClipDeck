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
    static let background = Color(hex: "#F3F3FA")
    static let card = Color.white
    static let textPrimary = Color(hex: "#111114")
    static let textSecondary = Color(hex: "#71717A")

    static let pinboardColors = ["#F0453B", "#F5A623", "#38B44A", "#4E7CF6", "#8E5CF6", "#EC5CA8", "#F07830"]

    static let cardCornerRadius: CGFloat = 18
    static let capsuleCornerRadius: CGFloat = 24
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
