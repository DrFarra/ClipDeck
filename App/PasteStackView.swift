import SwiftUI
import SwiftData
import Observation

/// Cola de pegado secuencial. Guarda solo IDs; los elementos se resuelven
/// contra la base de datos al mostrarse.
@Observable
final class PasteStack {
    static let shared = PasteStack()

    var itemIDs: [UUID] = []
    var cursor: Int = 0

    private init() {
        if let saved = UserDefaults.standard.array(forKey: "pasteStack.ids") as? [String] {
            itemIDs = saved.compactMap(UUID.init(uuidString:))
        }
    }

    func add(_ id: UUID) {
        guard !itemIDs.contains(id) else { return }
        itemIDs.append(id)
        persist()
    }

    func remove(_ id: UUID) {
        itemIDs.removeAll { $0 == id }
        cursor = min(cursor, max(0, itemIDs.count - 1))
        persist()
    }

    func clear() {
        itemIDs = []
        cursor = 0
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        itemIDs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(itemIDs.map(\.uuidString), forKey: "pasteStack.ids")
    }
}

struct PasteStackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var stack = PasteStack.shared
    @State private var toast: String?

    private var resolvedItems: [ClipItem] {
        stack.itemIDs.compactMap { CaptureService.findByID($0, context: modelContext) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if resolvedItems.isEmpty {
                    ContentUnavailableView(
                        "Paste Stack vacío",
                        systemImage: "square.stack.3d.up",
                        description: Text("Añade elementos desde el menú contextual de cualquier tarjeta y pégalos en orden.")
                    )
                } else {
                    List {
                        ForEach(Array(resolvedItems.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(index == stack.cursor ? Color.accentColor : Theme.textSecondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.isSensitive ? "Contenido sensible" : item.displayTitle)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(item.type.label)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if index == stack.cursor {
                                    Text("Siguiente")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .onMove { stack.move(from: $0, to: $1) }
                        .onDelete { indexSet in
                            for index in indexSet {
                                stack.remove(resolvedItems[index].id)
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            copyNext()
                        } label: {
                            Label(stack.cursor == 0 ? "Empezar a pegar" : "Copiar siguiente",
                                  systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        HStack {
                            Button("Reiniciar") { stack.cursor = 0 }
                            Spacer()
                            Button("Vaciar", role: .destructive) { stack.clear() }
                        }
                        .font(.subheadline)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Paste Stack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
            }
        }
    }

    private func copyNext() {
        let items = resolvedItems
        guard stack.cursor < items.count else {
            stack.cursor = 0
            return
        }
        let item = items[stack.cursor]
        ClipboardWriter.copy(item)
        Haptics.light()
        showToast("Copiado \(stack.cursor + 1) de \(items.count) — pégalo donde quieras")
        stack.cursor += 1
        if stack.cursor >= items.count { stack.cursor = 0 }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if toast == text { toast = nil } }
        }
    }
}
