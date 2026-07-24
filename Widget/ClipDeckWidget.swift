import WidgetKit
import SwiftUI

private let appGroupID = "group.com.emilio.clipdeck"

struct ClipEntry: TimelineEntry {
    let date: Date
    let lastTitle: String
    let lastType: String
    let count: Int
}

struct ClipProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClipEntry {
        ClipEntry(date: .now, lastTitle: "Tu último elemento", lastType: "Texto", count: 12)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClipEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClipEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [readEntry()], policy: .after(next)))
    }

    private func readEntry() -> ClipEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        return ClipEntry(
            date: .now,
            lastTitle: defaults?.string(forKey: "widget.lastTitle") ?? "Sin elementos",
            lastType: defaults?.string(forKey: "widget.lastType") ?? "",
            count: defaults?.integer(forKey: "widget.count") ?? 0
        )
    }
}

struct ClipDeckWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClipEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(.tint)
                Spacer()
                Text("\(entry.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.lastTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
            if !entry.lastType.isEmpty {
                Text(entry.lastType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "clipdeck://"))
    }

    private var medium: some View {
        HStack(spacing: 12) {
            Link(destination: URL(string: "clipdeck://")!) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.tint)
                        Text("Clipboard")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    Spacer()
                    Text(entry.lastTitle)
                        .font(.caption)
                        .lineLimit(2)
                    Text("\(entry.count) elementos")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(spacing: 8) {
                Link(destination: URL(string: "clipdeck://search")!) {
                    Label("Buscar", systemImage: "magnifyingglass")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                }
                Link(destination: URL(string: "clipdeck://new")!) {
                    Label("Nuevo", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: 110)
        }
    }
}

struct ClipDeckWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClipDeckWidget", provider: ClipProvider()) { entry in
            ClipDeckWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("ClipDeck")
        .description("Acceso rápido a tu historial del portapapeles.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClipDeckWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClipDeckWidget()
    }
}
