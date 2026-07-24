import SwiftUI
import UniformTypeIdentifiers

struct ClipCardView: View {
    let item: ClipItem
    var selectionMode: Bool = false
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 4)
        .overlay(alignment: .topTrailing) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                    .padding(6)
            }
        }
    }

    @ViewBuilder private var cardBackground: some View {
        if item.type == .color, let hex = colorValue {
            Color(hex: hex)
        } else {
            Theme.card
        }
    }

    private var colorValue: String? {
        guard item.type == .color, let text = item.plainText else { return nil }
        return ContentClassifier.colorHex(from: text)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: item.type.systemImage)
                .font(.caption2)
            Text(item.type.label)
                .font(.caption2.weight(.medium))
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Spacer(minLength: 4)
            Text(item.createdAt, format: .relative(presentation: .named))
                .font(.caption2)
        }
        .foregroundStyle(headerColor)
        .lineLimit(1)
    }

    private var headerColor: Color {
        if let hex = colorValue {
            return Color.isLightHex(hex) ? .black.opacity(0.6) : .white.opacity(0.8)
        }
        return Theme.textSecondary
    }

    @ViewBuilder private var content: some View {
        if item.isSensitive {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text("Contenido sensible")
                    .font(.subheadline)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else {
            switch item.type {
            case .image:
                imageBody
            case .link:
                linkBody
            case .color:
                colorBody
            case .code:
                codeBody
            case .file:
                fileBody
            default:
                textBody
            }
        }
    }

    private var textBody: some View {
        Text(item.plainText ?? "")
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(8)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder private var imageBody: some View {
        if let data = item.assetData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Label("Imagen no disponible", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var imageHeight: CGFloat {
        guard let w = item.imageWidth, let h = item.imageHeight, w > 0 else { return 160 }
        let ratio = CGFloat(h) / CGFloat(w)
        return min(max(120, 160 * ratio), 260)
    }

    @ViewBuilder private var linkBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = item.previewImageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text(item.linkTitle ?? item.urlString ?? "")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if let domain = item.linkDomain {
                Text(domain)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var colorBody: some View {
        Text(colorValue ?? item.plainText ?? "")
            .font(.headline.monospaced())
            .foregroundStyle(colorValue.map { Color.isLightHex($0) ? Color.black : Color.white } ?? Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private var codeBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.plainText ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
            if let lang = item.detectedCodeLanguage {
                Text(lang)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var fileBody: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName ?? "Archivo")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let size = item.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var footer: some View {
        switch item.type {
        case .plainText, .code, .email, .phoneNumber:
            if let count = item.plainText?.count {
                Text("\(count) caracteres")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                Text("\(w) × \(h)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Copiado al portapapeles

enum ClipboardWriter {
    /// Vuelve a colocar un elemento en el portapapeles del sistema.
    static func copy(_ item: ClipItem, asPlainText: Bool = false) {
        let pasteboard = UIPasteboard.general
        switch item.type {
        case .image:
            if let data = item.assetData, let image = UIImage(data: data), !asPlainText {
                pasteboard.image = image
            } else if let text = item.recognizedText {
                pasteboard.string = text
            }
        case .file:
            if let data = item.assetData {
                let type = item.fileName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data
                pasteboard.setData(data, forPasteboardType: type.identifier)
            }
        case .link:
            pasteboard.string = item.urlString ?? item.plainText ?? ""
        default:
            pasteboard.string = item.plainText ?? ""
        }
        item.lastUsedAt = .now
        // Evita que la app recapture su propia copia.
        AppGroup.sharedDefaults.set(pasteboard.changeCount, forKey: SettingsKeys.lastPasteboardChange)
    }
}
