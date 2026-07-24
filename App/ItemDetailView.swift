import SwiftUI
import SwiftData

struct ItemDetailView: View {
    @Bindable var item: ClipItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var revealed = false
    @State private var editedText = ""
    @State private var editedURL = ""
    @State private var zoom: CGFloat = 1
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField

                    if item.isSensitive && !revealed {
                        sensitivePlaceholder
                    } else {
                        contentEditor
                    }

                    infoPanel
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(item.type.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { save(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                        ClipboardWriter.copy(item)
                        Haptics.light()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? "Copiado" : "Copiar",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { item.isFavorite.toggle() } label: {
                            Label(item.isFavorite ? "Quitar de favoritos" : "Favorito", systemImage: "star")
                        }
                        Button { item.isSensitive.toggle() } label: {
                            Label(item.isSensitive ? "Quitar marca sensible" : "Marcar como sensible",
                                  systemImage: "eye.slash")
                        }
                        if item.type == .link {
                            Button { regenerateLinkPreview() } label: {
                                Label("Regenerar vista previa", systemImage: "arrow.clockwise")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            modelContext.delete(item)
                            try? modelContext.save()
                            dismiss()
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                editedText = item.plainText ?? ""
                editedURL = item.urlString ?? ""
            }
        }
    }

    private var titleField: some View {
        TextField("Título (opcional)", text: Binding(
            get: { item.title ?? "" },
            set: { item.title = $0.isEmpty ? nil : $0 }
        ))
        .font(.headline)
        .textFieldStyle(.roundedBorder)
    }

    private var sensitivePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.largeTitle)
                .foregroundStyle(Theme.textSecondary)
            Text("Este elemento está marcado como sensible")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Button("Mostrar") { revealed = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var contentEditor: some View {
        switch item.type {
        case .image:
            if let data = item.assetData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnificationGesture()
                        .onChanged { zoom = max(1, $0) }
                        .onEnded { _ in withAnimation { zoom = 1 } })
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if let text = item.recognizedText, !text.isEmpty {
                    DisclosureGroup("Texto reconocido (OCR)") {
                        Text(text)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                if let data = item.previewImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                TextField("URL", text: $editedURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                if URL(string: editedURL) == nil {
                    Text("URL no válida")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let url = URL(string: editedURL) {
                    Link(destination: url) {
                        Label("Abrir enlace", systemImage: "safari")
                    }
                }
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        case .file:
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text(item.fileName ?? "Archivo")
                        .font(.headline)
                    if let size = item.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        case .color:
            let hex = ContentClassifier.colorHex(from: item.plainText ?? "") ?? "#FFFFFF"
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hex: hex))
                    .frame(height: 130)
                HStack {
                    Text(hex).font(.headline.monospaced())
                    Spacer()
                    Button("Copiar hex") {
                        UIPasteboard.general.string = hex
                        Haptics.light()
                    }
                    .buttonStyle(.bordered)
                }
            }
        default:
            TextEditor(text: $editedText)
                .font(item.type == .code ? .footnote.monospaced() : .body)
                .frame(minHeight: 260)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Tipo", item.type.label)
            infoRow("Creado", item.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let used = item.lastUsedAt {
                infoRow("Último uso", used.formatted(date: .abbreviated, time: .shortened))
            }
            if let source = item.sourceApp {
                infoRow("Origen", source)
            }
            if let text = item.plainText {
                infoRow("Caracteres", "\(text.count)")
            }
            if let size = item.fileSize {
                infoRow("Tamaño", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let w = item.imageWidth, let h = item.imageHeight {
                infoRow("Dimensiones", "\(w) × \(h)")
            }
            if !item.pinboards.isEmpty {
                infoRow("Pinboards", item.pinboards.map { $0.title }.joined(separator: ", "))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func save() {
        var changed = false
        if item.type != .image && item.type != .file && editedText != (item.plainText ?? "") {
            item.plainText = editedText
            item.contentHash = HashService.sha256(editedText)
            changed = true
        }
        if item.type == .link && editedURL != (item.urlString ?? ""), URL(string: editedURL) != nil {
            item.urlString = editedURL
            item.linkDomain = URL(string: editedURL)?.host
            changed = true
        }
        if changed { item.updatedAt = .now }
        try? modelContext.save()
    }

    private func regenerateLinkPreview() {
        guard let url = URL(string: editedURL) else { return }
        Task { @MainActor in
            let meta = await LinkMetadataService.fetch(for: url)
            item.linkTitle = meta.title
            item.previewImageData = meta.imageData
            item.updatedAt = .now
            try? modelContext.save()
        }
    }
}
