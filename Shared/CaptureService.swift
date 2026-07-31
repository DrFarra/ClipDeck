import Foundation
import UIKit
import SwiftData

/// Captura el contenido actual de UIPasteboard y lo convierte en ClipItem.
/// En iOS la lectura solo puede ocurrir con la app activa (o desde el teclado
/// con acceso completo, o desde la Share Extension).
@MainActor
enum CaptureService {

    /// Resultado de un intento de captura.
    enum Outcome {
        case saved(ClipItem)
        case duplicate(ClipItem)
        case ignored
        case empty
    }

    @discardableResult
    static func captureIfNeeded(context: ModelContext) -> Outcome {
        let pasteboard = UIPasteboard.general
        let defaults = AppGroup.sharedDefaults

        // Evitar relecturas del mismo contenido (y el aviso de pegado repetido).
        let lastCount = defaults.integer(forKey: SettingsKeys.lastPasteboardChange)
        guard pasteboard.changeCount != lastCount else { return .empty }
        defaults.set(pasteboard.changeCount, forKey: SettingsKeys.lastPasteboardChange)

        guard !defaults.bool(forKey: SettingsKeys.capturePaused) else { return .ignored }

        if pasteboard.hasImages {
            let saveImages = defaults.object(forKey: SettingsKeys.saveImages) as? Bool ?? true
            guard saveImages, let image = pasteboard.image,
                  let data = image.jpegData(compressionQuality: 0.9) else { return .ignored }
            return saveImage(data: data, size: image.size, context: context)
        }

        if pasteboard.hasURLs, let url = pasteboard.url {
            return saveText(url.absoluteString, context: context)
        }

        if pasteboard.hasStrings, let text = pasteboard.string {
            return saveText(text, context: context)
        }

        return .empty
    }

    // MARK: Guardar texto / enlace

    @discardableResult
    static func saveText(_ text: String, sourceApp: String? = nil, context: ModelContext) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Reglas de captura
        let rules = (try? context.fetch(FetchDescriptor<CaptureRule>())) ?? []
        var forcedSensitive = false
        for rule in rules where rule.isEnabled {
            if rule.minimumLength > 0 && trimmed.count < rule.minimumLength {
                if rule.action == .ignore { return .ignored }
            }
            if let pattern = rule.textPattern, !pattern.isEmpty,
               let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                switch rule.action {
                case .ignore: return .ignored
                case .markSensitive: forcedSensitive = true
                }
            }
        }

        let hash = HashService.sha256(trimmed)
        if let existing = findByHash(hash, context: context) {
            existing.lastUsedAt = .now
            if AppGroup.sharedDefaults.object(forKey: SettingsKeys.moveReusedToTop) as? Bool ?? true {
                existing.createdAt = .now
            }
            try? context.save()
            return .duplicate(existing)
        }

        let type = ContentClassifier.classify(text: trimmed)
        let sensitiveDetection = AppGroup.sharedDefaults.object(forKey: SettingsKeys.sensitiveDetection) as? Bool ?? true
        let isSensitive = forcedSensitive || (sensitiveDetection && ContentClassifier.looksSensitive(trimmed))

        let item = ClipItem(type: type,
                            plainText: trimmed,
                            urlString: type == .link ? trimmed : nil,
                            sourceApp: sourceApp,
                            contentHash: hash,
                            isSensitive: isSensitive)

        if type == .code {
            item.detectedCodeLanguage = ContentClassifier.detectCodeLanguage(trimmed)
        }
        if type == .link, let url = URL(string: trimmed) {
            item.linkDomain = url.host
        }

        context.insert(item)
        try? context.save()
        updateWidget(context: context)

        // Post-procesado asíncrono: metadatos del enlace
        if type == .link, let url = URL(string: trimmed) {
            let itemID = item.id
            Task { @MainActor in
                let meta = await LinkMetadataService.fetch(for: url)
                if let found = findByID(itemID, context: context) {
                    found.linkTitle = meta.title
                    found.previewImageData = meta.imageData
                    found.updatedAt = .now
                    try? context.save()
                }
            }
        }
        return .saved(item)
    }

    // MARK: Guardar imagen

    @discardableResult
    static func saveImage(data: Data, size: CGSize, sourceApp: String? = nil, context: ModelContext) -> Outcome {
        let hash = HashService.sha256(data)
        if let existing = findByHash(hash, context: context) {
            existing.lastUsedAt = .now
            try? context.save()
            return .duplicate(existing)
        }

        let item = ClipItem(type: .image, assetData: data, sourceApp: sourceApp, contentHash: hash)
        item.imageWidth = Int(size.width)
        item.imageHeight = Int(size.height)
        context.insert(item)
        try? context.save()
        updateWidget(context: context)

        // OCR en segundo plano
        if AppGroup.sharedDefaults.object(forKey: SettingsKeys.ocrEnabled) as? Bool ?? true {
            let itemID = item.id
            Task { @MainActor in
                let text = await OCRService.recognizeText(in: data)
                if let text, let found = findByID(itemID, context: context) {
                    found.recognizedText = text
                    found.updatedAt = .now
                    try? context.save()
                }
            }
        }
        return .saved(item)
    }

    // MARK: Guardar archivo (desde Share Extension)

    @discardableResult
    static func saveFile(data: Data, fileName: String, sourceApp: String? = nil, context: ModelContext) -> Outcome {
        let hash = HashService.sha256(data)
        if let existing = findByHash(hash, context: context) {
            existing.lastUsedAt = .now
            try? context.save()
            return .duplicate(existing)
        }
        let item = ClipItem(type: .file, assetData: data, fileName: fileName,
                            sourceApp: sourceApp, contentHash: hash)
        context.insert(item)
        try? context.save()
        updateWidget(context: context)
        return .saved(item)
    }

    // MARK: Utilidades

    static func findByHash(_ hash: String, context: ModelContext) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func findByID(_ id: UUID, context: ModelContext) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func updateWidget(context: ModelContext) {
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let latest = (try? context.fetch(descriptor))?.first
        let count = (try? context.fetchCount(FetchDescriptor<ClipItem>())) ?? 0
        WidgetSnapshot.update(lastTitle: latest.map { $0.isSensitive ? "Contenido protegido" : $0.displayTitle },
                              lastType: latest?.type.label,
                              count: count)
    }

    /// Elimina elementos más antiguos que la retención configurada
    /// (excepto favoritos y elementos en pinboards).
    static func purgeExpired(context: ModelContext) {
        let days = AppGroup.sharedDefaults.integer(forKey: SettingsKeys.retentionDays)
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.createdAt < cutoff })
        let expired = (try? context.fetch(descriptor)) ?? []
        for item in expired where !item.isFavorite && item.pinboards.isEmpty {
            context.delete(item)
        }
        try? context.save()
    }
}
