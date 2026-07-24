import UIKit
import SwiftUI
import SwiftData

/// Teclado personalizado: muestra el historial compartido y permite insertar
/// elementos sin salir de la app actual. Requiere «Permitir acceso completo»
/// para leer el contenedor compartido del App Group.
final class KeyboardViewController: UIInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = KeyboardRootView(
            hasFullAccess: self.hasFullAccess,
            needsSwitchKey: self.needsInputModeSwitchKey,
            insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            insertReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )

        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: 280)
        height.priority = .defaultHigh
        height.isActive = true
    }
}

// MARK: - Snapshot ligero para no pasar objetos @Model entre vistas

struct ClipSnapshot: Identifiable {
    let id: UUID
    let typeLabel: String
    let systemImage: String
    let preview: String
    let insertable: String?
    let imageData: Data?
    let isSensitive: Bool
}

// MARK: - Vista raíz del teclado

struct KeyboardRootView: View {
    let hasFullAccess: Bool
    let needsSwitchKey: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let insertReturn: () -> Void
    let nextKeyboard: () -> Void

    @State private var snapshots: [ClipSnapshot] = []
    @State private var favoritesOnly = false
    @State private var hint: String?

    var body: some View {
        VStack(spacing: 8) {
            header
            content
            bottomRow
        }
        .padding(10)
        .task(id: favoritesOnly) { loadItems() }
        .overlay(alignment: .center) {
            if let hint {
                Text(hint)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                favoritesOnly.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: favoritesOnly ? "star.fill" : "clock.arrow.circlepath")
                    Text(favoritesOnly ? "Favoritos" : "Clipboard")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("ClipDeck")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if !hasFullAccess {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.lock")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Activa «Permitir acceso completo» en Ajustes → General → Teclado para ver tu historial.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxHeight: .infinity)
        } else if snapshots.isEmpty {
            Text("Tu historial está vacío.\nCopia algo y abre ClipDeck.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snapshots) { snap in
                        Button { handleTap(snap) } label: {
                            card(snap)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func card(_ snap: ClipSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: snap.systemImage).font(.caption2)
                Text(snap.typeLabel).font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)

            if snap.isSensitive {
                Label("Sensible", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else if let data = snap.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 130, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(snap.preview)
                    .font(.caption)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(10)
        .frame(width: 150, height: 130, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            if needsSwitchKey {
                keyButton(systemImage: "globe") { nextKeyboard() }
            }
            Button {
                insertText(" ")
            } label: {
                Text("espacio")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            keyButton(systemImage: "delete.left") { deleteBackward() }
            keyButton(systemImage: "return") { insertReturn() }
        }
    }

    private func keyButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 46, height: 40)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: Datos

    private func loadItems() {
        guard hasFullAccess else { return }
        let container = ClipStore.makeContainer()
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 30
        let items = (try? context.fetch(descriptor)) ?? []
        snapshots = items
            .filter { favoritesOnly ? $0.isFavorite : true }
            .map { item in
                ClipSnapshot(id: item.id,
                             typeLabel: item.type.label,
                             systemImage: item.type.systemImage,
                             preview: item.displayTitle,
                             insertable: insertableText(for: item),
                             imageData: item.type == .image ? item.assetData : nil,
                             isSensitive: item.isSensitive)
            }
    }

    private func insertableText(for item: ClipItem) -> String? {
        switch item.type {
        case .link:  return item.urlString ?? item.plainText
        case .image: return nil
        case .file:  return nil
        default:     return item.plainText
        }
    }

    private func handleTap(_ snap: ClipSnapshot) {
        if let text = snap.insertable {
            insertText(text)
        } else if let data = snap.imageData, let image = UIImage(data: data) {
            UIPasteboard.general.image = image
            showHint("Copiado: mantén pulsado el campo y elige Pegar")
        } else {
            showHint("Este elemento no se puede insertar como texto")
        }
    }

    private func showHint(_ text: String) {
        withAnimation { hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { if hint == text { hint = nil } }
        }
    }
}
