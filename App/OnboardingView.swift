import SwiftUI

struct OnboardingView: View {
    @AppStorage(SettingsKeys.hasOnboarded) private var hasOnboarded = false
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
                        text: "iOS no permite leer el portapapeles en segundo plano. ClipDeck captura lo copiado al abrir la app, desde su teclado o desde la extensión de compartir. La primera vez, iOS te pedirá permiso para pegar."
                    ).tag(1)

                    OnboardingPage(
                        icon: "keyboard",
                        title: "Activa el teclado",
                        text: "Ajustes → General → Teclado → Teclados → Añadir nuevo teclado → Teclado ClipDeck. Activa «Permitir acceso completo» para que el teclado pueda leer tu historial."
                    ).tag(2)

                    OnboardingPage(
                        icon: "square.and.arrow.up",
                        title: "Guarda desde cualquier app",
                        text: "Usa el botón Compartir de iOS y elige ClipDeck para guardar páginas, imágenes, PDFs o texto directamente en tu historial."
                    ).tag(3)

                    OnboardingPage(
                        icon: "lock.shield",
                        title: "Privado por diseño",
                        text: "Todo se guarda y procesa en tu dispositivo. Puedes proteger la app con Face ID, pausar la captura y crear reglas para ignorar contenido sensible."
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
}

private struct OnboardingPage: View {
    let icon: String
    let title: String
    let text: String

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
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}
