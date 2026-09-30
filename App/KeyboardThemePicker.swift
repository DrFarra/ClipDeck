import SwiftUI

/// Elección del tema del teclado, con un teclado en miniatura de cada uno.
struct KeyboardThemePicker: View {
    @Binding var selection: String

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(KeyboardTheme.Family.allCases) { family in
                    let themes = KeyboardTheme.all.filter { $0.family == family }
                    if !themes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(family.rawValue)
                                .font(.headline)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(themes) { theme in
                                    KeyboardThemeCard(theme: theme, selected: theme.id == selection)
                                        .onTapGesture { choose(theme) }
                                }
                            }
                        }
                    }
                }
                Text("El tema se aplica la próxima vez que se abra el teclado. Los temas oscuros y claros mantienen su aspecto aunque cambie el modo del iPhone; Clásico, Cristal y Pizarra lo siguen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tema del teclado")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Se guarda aquí mismo, al tocar. La pantalla de ajustes guarda con su
    /// `onChange`, que con esta pantalla encima puede no llegar a ejecutarse
    /// antes de que el usuario salga de la app: el teclado seguía con el tema
    /// anterior.
    private func choose(_ theme: KeyboardTheme) {
        guard selection != theme.id else { return }
        selection = theme.id
        KbPrefs.store.set(theme.id, forKey: KbPrefs.theme)
        Haptics.light()
    }
}

/// Tarjeta de un tema: miniatura, nombre y para quién es.
struct KeyboardThemeCard: View {
    let theme: KeyboardTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyboardThemePreview(theme: theme)
                .frame(height: 92)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
            Text(theme.name)
                .font(.subheadline.weight(.semibold))
            Text(theme.audience)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Teclado en miniatura con los colores de un tema.
struct KeyboardThemePreview: View {
    let theme: KeyboardTheme
    /// En las miniaturas pequeñas las letras no se leerían: sólo las teclas.
    var showsLabels = true
    @Environment(\.colorScheme) private var systemScheme

    /// Los temas de apariencia fija se ven igual con el iPhone en claro o en oscuro.
    private var scheme: ColorScheme {
        switch theme.appearance {
        case .system: return systemScheme
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 5
            let gap: CGFloat = 3
            let keyH = (geo.size.height - pad * 2 - gap * 3) / 4
            let unit = (geo.size.width - pad * 2 - gap * 9) / 10
            VStack(spacing: gap) {
                row(letters: "QWERTYUIOP", unit: unit, height: keyH, gap: gap)
                row(letters: "ASDFGHJKLÑ", unit: unit, height: keyH, gap: gap)
                HStack(spacing: gap) {
                    key(theme.function, width: unit * 1.4, height: keyH, symbol: "shift")
                    ForEach(Array("ZXCVBNM"), id: \.self) { c in
                        key(theme.letter, width: (geo.size.width - pad * 2 - unit * 2.8 - gap * 8) / 7,
                            height: keyH, label: String(c))
                    }
                    key(theme.function, width: unit * 1.4, height: keyH, symbol: "delete.left")
                }
                HStack(spacing: gap) {
                    key(theme.function, width: unit * 1.6, height: keyH, label: "123")
                    key(theme.letter, width: geo.size.width - pad * 2 - unit * 3.6 - gap * 2, height: keyH)
                    key(theme.accentReturn ? theme.accent : theme.function, width: unit * 2, height: keyH,
                        symbol: "return", tint: theme.accentReturn ? theme.accentText : theme.text)
                }
            }
            .padding(pad)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(backdrop)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .environment(\.colorScheme, scheme)
        .accessibilityHidden(true)
    }

    private var backdrop: some View {
        let colors = theme.previewBackdrop.map { Color(uiColor: $0) }
        return LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                              startPoint: .top, endPoint: .bottom)
    }

    private func row(letters: String, unit: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(letters), id: \.self) { c in
                key(theme.letter, width: unit, height: height, label: String(c))
            }
        }
    }

    private func key(_ fill: UIColor, width: CGFloat, height: CGFloat,
                     label: String? = nil, symbol: String? = nil, tint: UIColor? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(theme.cornerRadius * 0.35, 2))
        return shape
            .fill(Color(uiColor: fill))
            .overlay(shape.strokeBorder(Color(uiColor: theme.keyBorder ?? .clear), lineWidth: theme.keyBorder == nil ? 0 : 0.75))
            .shadow(color: Color(uiColor: theme.keyShadow ?? .clear), radius: 0, x: 0, y: theme.keyShadow == nil ? 0 : 0.75)
            .overlay {
                if !showsLabels {
                    EmptyView()
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.45, weight: .medium))
                        .foregroundStyle(Color(uiColor: tint ?? theme.text))
                } else if let label {
                    Text(label)
                        .font(.system(size: height * 0.5, weight: theme.boldKeys ? .bold : .regular))
                        .foregroundStyle(Color(uiColor: tint ?? theme.text))
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: max(width, 1), height: max(height, 1))
    }
}
