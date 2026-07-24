import SwiftUI

/// Gestión del vocabulario personal del teclado: ver, buscar, editar,
/// eliminar y añadir palabras a mano.
struct LearnedWordsView: View {
    @State private var words: [WordEntry] = []
    @State private var blocked: [String] = []
    @State private var query = ""
    @State private var newWord = ""
    @State private var editing: WordEntry?
    @State private var editedText = ""
    @State private var message: String?

    struct WordEntry: Identifiable, Equatable {
        let id = UUID()
        var word: String
        var count: Int
    }

    private var filtered: [WordEntry] {
        guard !query.isEmpty else { return words }
        let q = query.lowercased()
        return words.filter { $0.word.contains(q) }
    }

    var body: some View {
        List {
            addSection
            if !filtered.isEmpty || !query.isEmpty {
                wordsSection
            }
            if !blocked.isEmpty {
                blockedSection
            }
            infoSection
        }
        .navigationTitle("Palabras aprendidas")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Buscar palabra")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { entry in
            editSheet(entry)
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.caption)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: Secciones

    @ViewBuilder private var addSection: some View {
        Section("Añadir palabra") {
            HStack {
                TextField("Nueva palabra", text: $newWord)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .onSubmit(addWord)
                Button("Añadir", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).count < 2)
            }
            Text("Las palabras que añadas se sugieren y nunca se autocorrigen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var wordsSection: some View {
        Section("Vocabulario (\(words.count))") {
            if filtered.isEmpty {
                Text("Sin resultados para «\(query)».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(filtered) { entry in
                Button {
                    editing = entry
                    editedText = entry.word
                } label: {
                    HStack {
                        Text(entry.word).foregroundStyle(.primary)
                        Spacer()
                        Text("\(entry.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteWords)
        }
    }

    @ViewBuilder private var blockedSection: some View {
        Section("Bloqueadas (\(blocked.count))") {
            ForEach(blocked, id: \.self) { w in
                HStack {
                    Text(w).foregroundStyle(.secondary)
                    Spacer()
                    Button("Desbloquear") {
                        WordLearner.unblock(w)
                        reload()
                        flash("«\(w)» vuelve a sugerirse")
                    }
                    .font(.caption)
                }
            }
            Text("Son las palabras que descartaste manteniéndolas pulsadas en la barra de sugerencias.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var infoSection: some View {
        Section {
            Button("Borrar todo el vocabulario", role: .destructive) {
                WordLearner.clear()
                reload()
                flash("Vocabulario vaciado")
            }
            Text("El número indica cuántas veces escribiste esa palabra. Todo se guarda solo en tu dispositivo.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Edición

    @ViewBuilder private func editSheet(_ entry: WordEntry) -> some View {
        NavigationStack {
            Form {
                Section("Palabra") {
                    TextField("Palabra", text: $editedText)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    LabeledContent("Veces escrita", value: "\(entry.count)")
                }
                Section {
                    Button("Eliminar", role: .destructive) {
                        WordLearner.remove(entry.word)
                        editing = nil
                        reload()
                        flash("«\(entry.word)» eliminada")
                    }
                }
            }
            .navigationTitle("Editar palabra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let ok = WordLearner.rename(entry.word, to: editedText)
                        editing = nil
                        reload()
                        flash(ok ? "Guardado" : "Nombre no válido")
                    }
                    .disabled(editedText.trimmingCharacters(in: .whitespaces).count < 2)
                }
            }
        }
    }

    // MARK: Acciones

    private func reload() {
        words = WordLearner.allWordsSorted().map { WordEntry(word: $0.word, count: $0.count) }
        blocked = WordLearner.blockedList()
    }

    private func addWord() {
        let ok = WordLearner.addManual(newWord)
        if ok {
            flash("«\(newWord.lowercased())» añadida")
            newWord = ""
            reload()
        } else {
            flash("Palabra no válida (2–24 letras, sin espacios)")
        }
    }

    private func deleteWords(at offsets: IndexSet) {
        let targets = offsets.map { filtered[$0].word }
        for w in targets { WordLearner.remove(w) }
        reload()
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if message == text { message = nil } }
        }
    }
}
