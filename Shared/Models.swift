import Foundation
import SwiftData

// MARK: - Tipos de contenido

enum ClipContentType: String, Codable, CaseIterable, Identifiable {
    case plainText
    case link
    case image
    case file
    case color
    case code
    case email
    case phoneNumber
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plainText:   return "Texto"
        case .link:        return "Enlace"
        case .image:       return "Imagen"
        case .file:        return "Archivo"
        case .color:       return "Color"
        case .code:        return "Código"
        case .email:       return "Correo"
        case .phoneNumber: return "Teléfono"
        case .unknown:     return "Otro"
        }
    }

    var systemImage: String {
        switch self {
        case .plainText:   return "text.alignleft"
        case .link:        return "link"
        case .image:       return "photo"
        case .file:        return "doc"
        case .color:       return "paintpalette"
        case .code:        return "chevron.left.forwardslash.chevron.right"
        case .email:       return "envelope"
        case .phoneNumber: return "phone"
        case .unknown:     return "questionmark.circle"
        }
    }
}

// MARK: - Elemento del portapapeles

@Model
final class ClipItem {
    @Attribute(.unique) var id: UUID
    var typeRaw: String

    var title: String?
    var plainText: String?
    var urlString: String?

    @Attribute(.externalStorage) var assetData: Data?
    @Attribute(.externalStorage) var previewImageData: Data?

    var fileName: String?
    var fileSize: Int64?
    var imageWidth: Int?
    var imageHeight: Int?

    var sourceApp: String?

    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    var recognizedText: String?
    var detectedCodeLanguage: String?
    var linkTitle: String?
    var linkDomain: String?

    var contentHash: String
    var isSensitive: Bool
    var isFavorite: Bool

    var pinboards: [Pinboard]

    init(type: ClipContentType,
         title: String? = nil,
         plainText: String? = nil,
         urlString: String? = nil,
         assetData: Data? = nil,
         fileName: String? = nil,
         sourceApp: String? = nil,
         contentHash: String,
         isSensitive: Bool = false) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.title = title
        self.plainText = plainText
        self.urlString = urlString
        self.assetData = assetData
        self.previewImageData = nil
        self.fileName = fileName
        self.fileSize = assetData.map { Int64($0.count) }
        self.imageWidth = nil
        self.imageHeight = nil
        self.sourceApp = sourceApp
        self.createdAt = .now
        self.updatedAt = .now
        self.lastUsedAt = nil
        self.recognizedText = nil
        self.detectedCodeLanguage = nil
        self.linkTitle = nil
        self.linkDomain = nil
        self.contentHash = contentHash
        self.isSensitive = isSensitive
        self.isFavorite = false
        self.pinboards = []
    }

    var type: ClipContentType {
        get { ClipContentType(rawValue: typeRaw) ?? .unknown }
        set { typeRaw = newValue.rawValue }
    }

    /// Texto combinado para búsqueda.
    var searchBlob: String {
        [title, plainText, urlString, linkTitle, linkDomain, recognizedText, fileName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let linkTitle, !linkTitle.isEmpty { return linkTitle }
        if let plainText, !plainText.isEmpty {
            return String(plainText.prefix(60))
        }
        if let fileName { return fileName }
        if let urlString { return urlString }
        return type.label
    }
}

// MARK: - Pinboard

@Model
final class Pinboard {
    @Attribute(.unique) var id: UUID
    var title: String
    var colorHex: String
    var iconName: String?
    var sortOrder: Int
    var createdAt: Date

    @Relationship(inverse: \ClipItem.pinboards)
    var items: [ClipItem]

    init(title: String, colorHex: String = "#4E7CF6", iconName: String? = nil, sortOrder: Int = 0) {
        self.id = UUID()
        self.title = title
        self.colorHex = colorHex
        self.iconName = iconName
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.items = []
    }
}

// MARK: - Reglas de captura

enum CaptureRuleAction: String, Codable, CaseIterable, Identifiable {
    case ignore
    case markSensitive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ignore:        return "No guardar"
        case .markSensitive: return "Marcar como sensible"
        }
    }
}

@Model
final class CaptureRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var textPattern: String?
    var minimumLength: Int
    var actionRaw: String
    var isEnabled: Bool

    init(name: String, textPattern: String? = nil, minimumLength: Int = 0, action: CaptureRuleAction = .ignore) {
        self.id = UUID()
        self.name = name
        self.textPattern = textPattern
        self.minimumLength = minimumLength
        self.actionRaw = action.rawValue
        self.isEnabled = true
    }

    var action: CaptureRuleAction {
        get { CaptureRuleAction(rawValue: actionRaw) ?? .ignore }
        set { actionRaw = newValue.rawValue }
    }
}
