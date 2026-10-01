import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum HistorySource: Hashable {
    case clipboard
    case favorites
    case pinboard(UUID)
}

struct HistoryView: View {
    @Binding var deepLink: DeepLink?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var allItems: [ClipItem]
    @Query(sort: \Pinboard.sortOrder) private var pinboards: [Pinboard]

    @AppStorage(SettingsKeys.capturePaused, store: AppGroup.sharedDefaults) private var capturePaused = false
    @AppStorage(SettingsKeys.confirmDelete, store: AppGroup.sharedDefaults) private var confirmDelete = true
    @AppStorage(PasteboardWatch.askModeKey, store: AppGroup.sharedDefaults) private var askMode = false
    @AppStorage(PasteboardWatch.askTipDismissedKey, store: AppGroup.sharedDefaults) private var askTipDismissed = false

    @State private var source: HistorySource = .clipboard
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []

    @State private var showSearch = false
    @State private var showSourcePicker = false
    @State private var showSettings = false
    @State private var showNewText = false
    @State private var showNewPinboard = false
    @State private var showPasteStack = false
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false
    @State private var detailItem: ClipItem?
    @State private var pinboardTargetItems: [ClipItem] = []
    @State private var toastText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if filteredItems.isEmpty {
                    emptyState
                } else {
                    masonryGrid
                }
            }
            .navigationTitle(sourceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if selectionMode {
                    selectionBar
                } else {
                    floatingBar
                }
            }
            .overlay(alignment: .top) {
                if let toastText {
                    Text(toastText)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule(), interactive: false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 4)
                }
            }
        }
        .sheet(isPresented: $showSearch) { SearchView(onCopy: { showToast("Copiado") }) }
        .sheet(isPresented: $showSourcePicker) {
            SourcePickerSheet(source: $source, pinboards: pinboards, createPinboard: { showNewPinboard = true })
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNewText) { NewTextItemView() }
        .sheet(isPresented: $showNewPinboard) { PinboardEditorView() }
        .sheet(isPresented: $showPasteStack) { PasteStackView() }
        .sheet(item: $detailItem) { item in ItemDetailView(item: item) }
        .sheet(isPresented: Binding(get: { !pinboardTargetItems.isEmpty },
                                    set: { if !$0 { pinboardTargetItems = [] } })) {
            AddToPinboardSheet(items: pinboardTargetItems)
                .presentationDetents([.medium])
        }
        .confirmationDialog("¿Vaciar todo el historial?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Vaciar historial", role: .destructive) { clearHistory() }
        }
        .confirmationDialog("¿Eliminar \(selectedIDs.count) elementos?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) { deleteSelected() }
        }
        .onChange(of: deepLink) { _, link in
            guard let link else { return }
            switch link.kind {
            case .search: showSearch = true
            case .newItem: showNewText = true
            }
            deepLink = nil
        }
    }

    // MARK: Datos

    private var filteredItems: [ClipItem] {
        switch source {
        case .clipboard:
            return allItems
        case .favorites:
            return allItems.filter { $0.isFavorite }
        case .pinboard(let id):
            return allItems.filter { $0.pinboards.contains { $0.id == id } }
        }
    }

    private var sourceTitle: String {
        switch source {
        case .clipboard: return "Clipboard"
        case .favorites: return "Favoritos"
        case .pinboard(let id): return pinboards.first { $0.id == id }?.title ?? "Pinboard"
        }
    }

    // MARK: Cuadrícula masonry

    private var masonryGrid: some View {
        ScrollView {
            let columns = distributeInColumns(filteredItems)
            VStack(spacing: 10) {
                if showAskCard { askModeCard }
                HStack(alignment: .top, spacing: 10) {
                    column(for: columns.0)
                    column(for: columns.1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
    }

    private func column(for items: [ClipItem]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { item in
                ClipCardView(item: item,
                             selectionMode: selectionMode,
                             isSelected: selectedIDs.contains(item.id))
                    .onTapGesture { handleTap(item) }
                    .contextMenu { contextMenu(for: item) }
            }
        }
    }

    private func distributeInColumns(_ items: [ClipItem]) -> ([ClipItem], [ClipItem]) {
        var left: [ClipItem] = []
        var right: [ClipItem] = []
        var leftHeight: CGFloat = 0
        var rightHeight: CGFloat = 0
        for item in items {
            let h = estimatedHeight(item)
            if leftHeight <= rightHeight {
                left.append(item); leftHeight += h
            } else {
                right.append(item); rightHeight += h
            }
        }
        return (left, right)
    }

    private func estimatedHeight(_ item: ClipItem) -> CGFloat {
        if item.isSensitive { return 90 }
        switch item.type {
        case .image: return 200
        case .link: return item.previewImageData != nil ? 210 : 120
        case .color: return 130
        case .file: return 110
        case .code:
            let lines = min(8, (item.plainText ?? "").split(separator: "\n").count)
            return CGFloat(lines) * 16 + 80
        default:
            let lines = min(8, max(1, (item.plainText ?? "").count / 32))
            return CGFloat(lines) * 18 + 70
        }
    }

    // MARK: Interacciones

    private func handleTap(_ item: ClipItem) {
        if selectionMode {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else {
            ClipboardWriter.copy(item)
            Haptics.light()
            showToast("Copiado")
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button { ClipboardWriter.copy(item); showToast("Copiado") } label: {
            Label("Copiar", systemImage: "doc.on.doc")
        }
        Button { ClipboardWriter.copy(item, asPlainText: true); showToast("Copiado como texto") } label: {
            Label("Copiar como texto plano", systemImage: "textformat")
        }
        Button { detailItem = item } label: {
            Label("Vista previa", systemImage: "eye")
        }
        Button { item.isFavorite.toggle(); try? modelContext.save() } label: {
            Label(item.isFavorite ? "Quitar de favoritos" : "Favorito",
                  systemImage: item.isFavorite ? "star.slash" : "star")
        }
        Button { pinboardTargetItems = [item] } label: {
            Label("Añadir a pinboard…", systemImage: "pin")
        }
        Button { PasteStack.shared.add(item.id); showToast("Añadido al Stack") } label: {
            Label("Añadir a Paste Stack", systemImage: "square.stack.3d.up")
        }
        if item.type == .link, let url = URL(string: item.urlString ?? "") {
            Button { openURL(url) } label: {
                Label("Abrir enlace", systemImage: "safari")
            }
        }
        Divider()
        Button(role: .destructive) {
            modelContext.delete(item)
            try? modelContext.save()
            CaptureService.updateWidget(context: modelContext)
        } label: {
            Label("Eliminar", systemImage: "trash")
        }
    }

    // MARK: Barras

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selectionMode {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancelar") {
                    selectionMode = false
                    selectedIDs = []
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(selectedIDs.count) seleccionados")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Seleccionar") { selectionMode = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showNewText = true } label: {
                        Label("Nueva entrada de texto", systemImage: "square.and.pencil")
                    }
                    Button { pasteCurrent() } label: {
                        Label("Pegar del portapapeles", systemImage: "doc.on.clipboard")
                    }
                    Button { showNewPinboard = true } label: {
                        Label("Crear pinboard", systemImage: "pin")
                    }
                    Button { showPasteStack = true } label: {
                        Label("Paste Stack", systemImage: "square.stack.3d.up")
                    }
                    Button { capturePaused.toggle() } label: {
                        Label(capturePaused ? "Reanudar captura" : "Pausar captura",
                              systemImage: capturePaused ? "play" : "pause")
                    }
                    Divider()
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label("Vaciar historial", systemImage: "trash")
                    }
                    Button { showSettings = true } label: {
                        Label("Ajustes", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var floatingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .frame(width: 50, height: 50)
                        .liquidGlass(in: Circle())
                }

                Button { showSourcePicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(sourceTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .liquidGlass(in: Capsule())
                }

                Menu {
                    Button { showNewText = true } label: {
                        Label("Nueva entrada de texto", systemImage: "square.and.pencil")
                    }
                    Button { pasteCurrent() } label: {
                        Label("Pegar del portapapeles", systemImage: "doc.on.clipboard")
                    }
                    Button { showNewPinboard = true } label: {
                        Label("Crear pinboard", systemImage: "pin")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 50, height: 50)
                        .liquidGlass(in: Circle())
                }
            }
            .foregroundStyle(Theme.textPrimary)

            // Mientras iOS pregunte antes de cada lectura, el botón Pegar del
            // sistema queda a mano: con él no pregunta. Va fuera del estilo de
            // los demás: iOS no lo deja usar si se altera su aspecto.
            if askMode {
                PasteButton(supportedContentTypes: Self.pasteTypes) { providers in
                    Task { await paste(providers) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var selectionBar: some View {
        HStack(spacing: 20) {
            Button {
                pinboardTargetItems = selectedItems
            } label: { Label("Pinboard", systemImage: "pin") }

            Button {
                for item in selectedItems { item.isFavorite = true }
                try? modelContext.save()
                exitSelection()
            } label: { Label("Favorito", systemImage: "star") }

            Button {
                for item in selectedItems { PasteStack.shared.add(item.id) }
                showToast("Añadidos al Stack")
                exitSelection()
            } label: { Label("Stack", systemImage: "square.stack.3d.up") }

            Button(role: .destructive) {
                if confirmDelete { showDeleteConfirm = true } else { deleteSelected() }
            } label: { Label("Eliminar", systemImage: "trash") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .liquidGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .disabled(selectedIDs.isEmpty)
    }

    private var selectedItems: [ClipItem] {
        allItems.filter { selectedIDs.contains($0.id) }
    }

    // MARK: Estados vacíos

    private var emptyState: some View {
        VStack(spacing: 12) {
            if showAskCard {
                askModeCard
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            Image(systemName: source == .clipboard ? "doc.on.clipboard" : "pin")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text(source == .clipboard ? "Tu historial está vacío" : "Todavía no hay elementos")
                .font(.headline)
            Text(source == .clipboard
                 ? "Copia texto, enlaces o imágenes y aparecerán aquí al abrir la app."
                 : "Añade elementos desde tu historial con el menú contextual.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if source == .clipboard {
                // El botón del sistema: iOS no pregunta «¿Permitir pegar?».
                PasteButton(supportedContentTypes: Self.pasteTypes) { providers in
                    Task { await paste(providers) }
                }
                .buttonBorderShape(.capsule)
                .padding(.top, 8)
            }
        }
    }

    // MARK: iOS pregunta antes de pegar

    private static let pasteTypes: [UTType] = [.image, .url, .plainText]

    private var showAskCard: Bool {
        askMode && !askTipDismissed && source == .clipboard && !selectionMode
    }

    /// Con «Pegar desde otras apps» en Preguntar, cada lectura saca la alerta
    /// de iOS. Entonces ClipDeck deja de leer por su cuenta y lo explica aquí.
    private var askModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS pregunta antes de cada pegado")
                        .font(.subheadline.weight(.semibold))
                    Text("Para no molestarte, ClipDeck ya no lee lo que copias por su cuenta: toca Pegar para guardarlo. Si prefieres que se guarde solo, en Ajustes → ClipDeck → Pegar desde otras apps elige «Permitir».")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { withAnimation { askTipDismissed = true } } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Cerrar")
            }
            HStack(spacing: 10) {
                PasteButton(supportedContentTypes: Self.pasteTypes) { providers in
                    Task { await paste(providers) }
                }
                .buttonBorderShape(.capsule)
                Button("Abrir Ajustes") { openAppSettings() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func openAppSettings() {
        // Al volver se prueba de nuevo a leer solo: si sigue en Preguntar,
        // iOS preguntará una vez y ClipDeck volverá a esperar al botón.
        askMode = false
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: Acciones

    /// «Pegar del portapapeles» del menú: lo pidió el usuario, así que se lee
    /// aunque iOS vaya a preguntar.
    private func pasteCurrent() {
        Task {
            let reading = await CaptureService.readPasteboard(lightweight: false)
            report(CaptureService.ingest(reading, context: modelContext, lightweight: false,
                                         userInitiated: true))
        }
    }

    private func paste(_ providers: [NSItemProvider]) async {
        report(await CaptureService.save(pasted: providers, context: modelContext))
    }

    private func report(_ outcome: CaptureService.Outcome) {
        switch outcome {
        case .saved: showToast("Guardado")
        case .duplicate, .unchanged: showToast("Ya estaba guardado")
        case .ignored: showToast("Ignorado por tus reglas")
        case .empty: showToast("El portapapeles está vacío")
        case .denied: showToast("iOS no dejó leer lo copiado")
        case .waitingForUser: break
        }
    }

    private func deleteSelected() {
        for item in selectedItems { modelContext.delete(item) }
        try? modelContext.save()
        CaptureService.updateWidget(context: modelContext)
        exitSelection()
    }

    private func clearHistory() {
        for item in allItems { modelContext.delete(item) }
        try? modelContext.save()
        CaptureService.updateWidget(context: modelContext)
    }

    private func exitSelection() {
        selectionMode = false
        selectedIDs = []
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.3)) {
                if toastText == text { toastText = nil }
            }
        }
    }
}

// MARK: - Nueva entrada de texto

struct NewTextItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(12)
                .navigationTitle("Nueva entrada")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") {
                            CaptureService.saveText(text, sourceApp: "ClipDeck", context: modelContext)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
