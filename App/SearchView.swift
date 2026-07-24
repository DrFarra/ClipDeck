import SwiftUI
import SwiftData

enum DateFilter: String, CaseIterable, Identifiable {
    case all = "Todo"
    case today = "Hoy"
    case week = "Semana"
    case month = "Mes"

    var id: String { rawValue }

    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .all:   return nil
        case .today: return cal.startOfDay(for: .now)
        case .week:  return cal.date(byAdding: .day, value: -7, to: .now)
        case .month: return cal.date(byAdding: .month, value: -1, to: .now)
        }
    }
}

struct SearchView: View {
    var onCopy: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var allItems: [ClipItem]

    @State private var query = ""
    @State private var selectedTypes: Set<ClipContentType> = []
    @State private var dateFilter: DateFilter = .all
    @State private var favoritesOnly = false
    @State private var detailItem: ClipItem?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterChips
                resultsList
            }
            .background(Theme.background)
            .navigationTitle("Buscar")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Contenido, título, URL, OCR…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .sheet(item: $detailItem) { ItemDetailView(item: $0) }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Fecha", selection: $dateFilter) {
                        ForEach(DateFilter.allCases) { f in Text(f.rawValue).tag(f) }
                    }
                } label: {
                    chipLabel(dateFilter == .all ? "Fecha" : dateFilter.rawValue,
                              systemImage: "calendar",
                              active: dateFilter != .all)
                }

                Button { favoritesOnly.toggle() } label: {
                    chipLabel("Favoritos", systemImage: "star", active: favoritesOnly)
                }

                ForEach(ClipContentType.allCases.filter { $0 != .unknown }) { type in
                    Button {
                        if selectedTypes.contains(type) { selectedTypes.remove(type) }
                        else { selectedTypes.insert(type) }
                    } label: {
                        chipLabel(type.label, systemImage: type.systemImage,
                                  active: selectedTypes.contains(type))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func chipLabel(_ text: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.caption)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(active ? Color.accentColor.opacity(0.15) : Color(.systemGray6), in: Capsule())
        .foregroundStyle(active ? Color.accentColor : Theme.textPrimary)
    }

    private var results: [ClipItem] {
        let terms = query.lowercased()
            .split(separator: " ")
            .map(String.init)

        return allItems.filter { item in
            if favoritesOnly && !item.isFavorite { return false }
            if !selectedTypes.isEmpty && !selectedTypes.contains(item.type) { return false }
            if let cutoff = dateFilter.cutoff, item.createdAt < cutoff { return false }
            guard !terms.isEmpty else { return true }
            let blob = item.searchBlob
            return terms.allSatisfy { blob.contains($0) }
        }
        .sorted { a, b in
            guard !terms.isEmpty else { return a.createdAt > b.createdAt }
            let aTitle = a.displayTitle.lowercased()
            let bTitle = b.displayTitle.lowercased()
            let aRank = terms.contains(where: { aTitle.contains($0) }) ? 0 : 1
            let bRank = terms.contains(where: { bTitle.contains($0) }) ? 0 : 1
            if aRank != bRank { return aRank < bRank }
            return a.createdAt > b.createdAt
        }
    }

    private var resultsList: some View {
        List {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
            ForEach(results) { item in
                Button {
                    ClipboardWriter.copy(item)
                    Haptics.light()
                    onCopy()
                    dismiss()
                } label: {
                    resultRow(item)
                }
                .swipeActions(edge: .trailing) {
                    Button { detailItem = item } label: {
                        Label("Vista previa", systemImage: "eye")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func resultRow(_ item: ClipItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.systemImage)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.isSensitive ? "Contenido sensible" : item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.type.label)
                    if let domain = item.linkDomain { Text("· \(domain)") }
                    Text("· ") + Text(item.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            if let data = item.assetData, item.type == .image, let ui = UIImage(data: data), !item.isSensitive {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 2)
    }
}
