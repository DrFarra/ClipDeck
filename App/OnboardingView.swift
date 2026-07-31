import SwiftUI
import UIKit

struct OnboardingView: View {
    @AppStorage(SettingsKeys.hasOnboarded, store: AppGroup.sharedDefaults) private var hasOnboarded = false
    @Environment(\.openURL) private var openURL
    @State private var page = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack {
                TabView(selection: $page) {
                    OnboardingPage(
                        icon: "doc.on.clipboard.fill",
                        title: "Nunca vuelvas a perder algo que copiaste",
                        text: "Cada texto, enlace o imagen que copias se convierte en una tarjeta visual que puedes recuperar cuando quieras."
                    ).tag(0)

                    OnboardingPage(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Así funciona en iPhone",
                        text: "iOS no permite leer el portapapeles en segundo plano. ClipDeck captura lo copiado al abrir la app, al abrir su teclado o desde la extensión de compartir."
                    ).tag(1)

                    OnboardingPage(
                        icon: "keyboard",
                        title: "Activa el teclado",
                        text: "En Ajustes de ClipDeck: Teclados → activa ClipDeck y «Permitir acceso completo». Con eso el teclado muestra tu historial y captura lo que copies sin abrir la app.",
                        buttonTitle: "Abrir Ajustes de ClipDeck",
                        buttonAction: { openSettings() }
                    ).tag(2)

                    OnboardingPage(
                        icon: "square.and.arrow.up",
                        title: "Guarda desde cualquier app",
                        text: "Usa el botón Compartir de iOS y elige ClipDeck. Si no aparece: desliza la fila de apps → Más → Editar → activa ClipDeck."
                    ).tag(3)

                    OnboardingPage(
                        icon: "checkmark.shield",
                        title: "Último paso",
                        text: "En Ajustes de ClipDeck pon «Pegar de otras apps» en Permitir para que iOS no pregunte cada vez. Todo se guarda solo en tu dispositivo; puedes activar Face ID cuando quieras.",
                        buttonTitle: "Abrir Ajustes y terminar",
                        buttonAction: {
                            openSettings()
                            hasOnboarded = true
                        }
                    ).tag(4)
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < 4 {
                        withAnimation { page += 1 }
                    } else {
                        hasOnboarded = true
                    }
                } label: {
                    Text(page < 4 ? "Continuar" : "Empezar")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

private struct OnboardingPage: View {
    let icon: String
    let title: String
    let text: String
    var buttonTitle: String? = nil
    var buttonAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let buttonTitle, let buttonAction {
                Button(buttonTitle, action: buttonAction)
                    .buttonStyle(.bordered)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}
