import SwiftUI
import SwiftData

// MARK: - Selector de origen (Clipboard / pinboards)

struct SourcePickerSheet: View {
    @Binding var source: HistorySource
    let pinboards: [Pinboard]
    var createPinboard: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { source = .clipboard; dismiss() } label: {
                    row(icon: "clock.arrow.circlepath", color: .gray, title: "Clipboard",
                        selected: source == .clipboard)
                }
                Button { source = .favorites; dismiss() } label: {
                    row(icon: "star.fill", color: .yellow, title: "Favoritos",
                        selected: source == .favorites)
                }

                Section("Pinboards") {
                    ForEach(pinboards) { board in
                        Button { source = .pinboard(board.id); dismiss() } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: board.colorHex))
                                    .frame(width: 12, height: 12)
                                Text(board.title)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("\(board.items.count)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                if source == .pinboard(board.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                    Button { dismiss(); createPinboard() } label: {
                        Label("Crear pinboard…", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Pinboards")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(icon: String, color: Color, title: String, selected: Bool) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Crear / editar pinboard

struct PinboardEditorView: View {
    var pinboard: Pinboard? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existing: [Pinboard]

    @State private var name = ""
    @State private var colorHex = Theme.pinboardColors[3]

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Ej. Enlaces útiles", text: $name)
                }
                Section("Color") {
                    HStack(spacing: 14) {
                        ForEach(Theme.pinboardColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if hex == colorHex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(pinboard == nil ? "Nuevo pinboard" : "Editar pinboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let pinboard {
                    name = pinboard.title
                    colorHex = pinboard.colorHex
                }
            }
        }
    }

    private func save() {
        if let pinboard {
            pinboard.title = name
            pinboard.colorHex = colorHex
        } else {
            let board = Pinboard(title: name, colorHex: colorHex, sortOrder: existing.count)
            modelContext.insert(board)
        }
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Añadir elementos a pinboards

struct AddToPinboardSheet: View {
    let items: [ClipItem]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Pinboard.sortOrder) private var pinboards: [Pinboard]
    @State private var showNewPinboard = false

    var body: some View {
        NavigationStack {
            List {
                if pinboards.isEmpty {
                    Text("Aún no tienes pinboards. Crea el primero.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(pinboards) { board in
                    Button { toggle(board) } label: {
                        HStack {
                            Circle().fill(Color(hex: board.colorHex)).frame(width: 12, height: 12)
                            Text(board.title).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if allItemsIn(board) {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                Button { showNewPinboard = true } label: {
                    Label("Crear pinboard…", systemImage: "plus")
                }
            }
            .navigationTitle(items.count == 1 ? "Añadir a pinboard" : "Añadir \(items.count) elementos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .sheet(isPresented: $showNewPinboard) { PinboardEditorView() }
        }
    }

    private func allItemsIn(_ board: Pinboard) -> Bool {
        items.allSatisfy { item in item.pinboards.contains { $0.id == board.id } }
    }

    private func toggle(_ board: Pinboard) {
        if allItemsIn(board) {
            for item in items {
                item.pinboards.removeAll { $0.id == board.id }
            }
        } else {
            for item in items where !item.pinboards.contains(where: { $0.id == board.id }) {
                item.pinboards.append(board)
            }
        }
        try? modelContext.save()
    }
}
