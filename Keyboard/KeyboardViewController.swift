import UIKit
import SwiftUI
import SwiftData

/// Teclado QWERTY español completo con barra de herramientas y panel de
/// historial del portapapeles. Con «Permitir acceso completo» captura el
/// portapapeles al aparecer, sin necesidad de abrir la app.
final class KeyboardViewController: UIInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = KeyboardRootView(
            hasFullAccess: self.hasFullAccess,
            needsSwitchKey: self.needsInputModeSwitchKey,
            insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
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

        let height = view.heightAnchor.constraint(equalToConstant: 300)
        height.priority = .defaultHigh
        height.isActive = true
    }
}

// MARK: - Snapshot ligero

struct ClipSnapshot: Identifiable {
    let id: UUID
    let typeLabel: String
    let systemImage: String
    let preview: String
    let insertable: String?
    let imageData: Data?
    let isSensitive: Bool
}

// MARK: - Vista raíz

struct KeyboardRootView: View {
    let hasFullAccess: Bool
    let needsSwitchKey: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let nextKeyboard: () -> Void

    enum ShiftState { case off, on, caps }

    @State private var shift: ShiftState = .on
    @State private var numbersMode = false
    @State private var showClipboard = false
    @State private var favoritesOnly = false
    @State private var snapshots: [ClipSnapshot] = []
    @State private var hint: String?

    var body: some View {
        VStack(spacing: 7) {
            toolbar
            if showClipboard {
                clipboardStrip
            }
            keyboard
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .task { captureAndLoad() }
        .overlay {
            if let hint {
                Text(hint)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    // MARK: Barra de herramientas

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                showClipboard.toggle()
                if showClipboard { captureAndLoad() }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 30)
                    .background(showClipboard ? Color.accentColor.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(showClipboard ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)

            if showClipboard {
                Button {
                    favoritesOnly.toggle()
                    loadItems()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: favoritesOnly ? "star.fill" : "clock.arrow.circlepath")
                        Text(favoritesOnly ? "Favoritos" : "Recientes").font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("ClipDeck")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(height: 32)
    }

    // MARK: Panel del portapapeles

    @ViewBuilder private var clipboardStrip: some View {
        if !hasFullAccess {
            Text("Activa «Permitir acceso completo» en Ajustes → ClipDeck → Teclados para ver tu historial aquí.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 84)
        } else if snapshots.isEmpty {
            Text("Historial vacío. Copia algo y vuelve a abrir este panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 84)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(snapshots) { snap in
                        Button { handleTap(snap) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 3) {
                                    Image(systemName: snap.systemImage).font(.caption2)
                                    Text(snap.typeLabel).font(.caption2)
                                }
                                .foregroundStyle(.secondary)

                                if snap.isSensitive {
                                    Label("Sensible", systemImage: "eye.slash")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if let data = snap.imageData, let ui = UIImage(data: data) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 46)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Text(snap.preview)
                                        .font(.caption)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .frame(width: 136, height: 84, alignment: .topLeading)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 84)
        }
    }

    // MARK: Teclado

    private var letterRows: [[String]] {
        [["q","w","e","r","t","y","u","i","o","p"],
         ["a","s","d","f","g","h","j","k","l","ñ"]]
    }

    private var numberRows: [[String]] {
        [["1","2","3","4","5","6","7","8","9","0"],
         ["-","/",":",";","(",")","€","&","@","\""]]
    }

    private var thirdRowLetters: [String] { ["z","x","c","v","b","n","m"] }
    private var thirdRowSymbols: [String] { [".",",","¿","?","¡","!","'"] }

    private var keyboard: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { index in
                HStack(spacing: 5) {
                    ForEach((numbersMode ? numberRows : letterRows)[index], id: \.self) { key in
                        characterKey(key)
                    }
                }
            }

            HStack(spacing: 5) {
                if numbersMode {
                    ForEach(thirdRowSymbols, id: \.self) { characterKey($0) }
                } else {
                    shiftKey
                    ForEach(thirdRowLetters, id: \.self) { characterKey($0) }
                }
                specialKey(systemImage: "delete.left", width: 42) { deleteBackward() }
            }

            HStack(spacing: 5) {
                specialKey(text: numbersMode ? "ABC" : "123", width: 46) {
                    numbersMode.toggle()
                }
                if needsSwitchKey {
                    specialKey(systemImage: "globe", width: 42) { nextKeyboard() }
                }
                Button {
                    insertText(" ")
                } label: {
                    Text("espacio")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                specialKey(systemImage: "return", width: 62) { insertText("\n") }
            }
        }
    }

    private func characterKey(_ key: String) -> some View {
        Button {
            let output = shift == .off ? key : key.uppercased()
            insertText(output)
            if shift == .on && !numbersMode { shift = .off }
        } label: {
            Text(shift == .off || numbersMode ? key : key.uppercased())
                .font(.system(size: 21))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var shiftKey: some View {
        let icon = shift == .caps ? "capslock.fill" : (shift == .on ? "shift.fill" : "shift")
        return Image(systemName: icon)
            .font(.body)
            .frame(width: 42, height: 42)
            .background(shift != .off ? Color(.systemGray3) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 7))
            .gesture(
                ExclusiveGesture(
                    TapGesture(count: 2).onEnded { shift = .caps },
                    TapGesture().onEnded { shift = shift == .off ? .on : .off }
                )
            )
    }

    private func specialKey(systemImage: String? = nil, text: String? = nil,
                            width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.body)
                } else {
                    Text(text ?? "").font(.subheadline)
                }
            }
            .frame(width: width, height: 42)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Datos

    private func captureAndLoad() {
        guard hasFullAccess else { return }
        let container = ClipStore.makeContainer()
        let context = ModelContext(container)
        // Captura lo que haya en el portapapeles ahora mismo: así no hace
        // falta abrir la app después de copiar en otra aplicación.
        CaptureService.captureIfNeeded(context: context)
        loadItems(context: context)
    }

    private func loadItems(context: ModelContext? = nil) {
        guard hasFullAccess else { return }
        let ctx = context ?? ModelContext(ClipStore.makeContainer())
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 30
        let items = (try? ctx.fetch(descriptor)) ?? []
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
