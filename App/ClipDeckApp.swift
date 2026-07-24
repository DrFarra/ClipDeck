import SwiftUI
import SwiftData
import LocalAuthentication

@main
struct ClipDeckApp: App {
    private let container = ClipStore.makeContainer()

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKeys.hasOnboarded) private var hasOnboarded = false
    @AppStorage(SettingsKeys.faceIDLock) private var faceIDLock = false
    @AppStorage(SettingsKeys.blurInSwitcher) private var blurInSwitcher = true
    @AppStorage(SettingsKeys.appearance) private var appearance = "system"

    @State private var isLocked = false
    @State private var isObscured = false
    @State private var pendingDeepLink: DeepLink?

    var body: some Scene {
        WindowGroup {
            ZStack {
                if hasOnboarded {
                    HistoryView(deepLink: $pendingDeepLink)
                } else {
                    OnboardingView()
                }

                if isObscured && blurInSwitcher {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .overlay(Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundStyle(.secondary))
                }

                if isLocked {
                    LockScreenView { unlock() }
                }
            }
            .tint(Theme.accent)
            .preferredColorScheme(colorScheme)
            .onOpenURL { url in
                pendingDeepLink = DeepLink(url: url)
            }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                isObscured = false
                if faceIDLock && isLocked == false && needsUnlockOnActivate {
                    isLocked = true
                    unlock()
                }
                needsUnlockOnActivate = false
                let context = container.mainContext
                CaptureService.captureIfNeeded(context: context)
                CaptureService.purgeExpired(context: context)
                // El vocabulario para escribir deslizando se arma una sola vez,
                // en segundo plano, a partir del diccionario del sistema.
                SwipeLexicon.buildIfNeeded()
            case .inactive:
                isObscured = true
            case .background:
                isObscured = true
                needsUnlockOnActivate = true
            @unknown default:
                break
            }
        }
    }

    @State private var needsUnlockOnActivate = true

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func unlock() {
        let laContext = LAContext()
        var error: NSError?
        guard laContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        laContext.evaluatePolicy(.deviceOwnerAuthentication,
                                 localizedReason: "Desbloquea tu historial del portapapeles") { success, _ in
            DispatchQueue.main.async {
                if success { isLocked = false }
            }
        }
    }
}

struct DeepLink: Equatable {
    enum Kind { case search, newItem }
    let kind: Kind

    init?(url: URL) {
        switch url.host ?? url.path.replacingOccurrences(of: "/", with: "") {
        case "search": kind = .search
        case "new": kind = .newItem
        default: return nil
        }
    }
}

struct LockScreenView: View {
    var retry: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.textSecondary)
                Text("ClipDeck está bloqueado")
                    .font(.headline)
                Button("Desbloquear") { retry() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
