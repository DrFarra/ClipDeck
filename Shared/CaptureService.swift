import Foundation
import UIKit
import SwiftData
import ImageIO
import UniformTypeIdentifiers

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
        /// Lo mismo que la última vez, o lo copió ClipDeck: no se toca nada.
        case unchanged
        /// Puede haber algo nuevo, pero leerlo haría que iOS preguntara: se
        /// espera a que el usuario toque Pegar.
        case waitingForUser
        /// iOS no lo dio: el usuario tocó «No permitir».
        case denied
    }

    /// Captura automática: al abrir la app o el panel del teclado.
    ///
    /// Sólo lee si puede haber algo nuevo (`PasteboardWatch`) y si iOS no va a
    /// preguntar. La lectura va en segundo plano porque se queda esperando
    /// mientras iOS muestra su alerta.
    ///
    /// - Parameter lightweight: modo para el teclado. Una extensión de teclado
    ///   tiene un límite de memoria muy bajo (unas decenas de MB) y si lo pasa
    ///   iOS la cierra sin avisar y vuelve al teclado del sistema. Decodificar
    ///   una captura de pantalla a tamaño completo, pasarle Vision (OCR) o
    ///   descargar la vista previa de un enlace basta para eso. En este modo la
    ///   imagen se guarda tal cual viene, sin decodificarla, y el OCR y los
    ///   metadatos los completa la app después (`processPending`).
    @discardableResult
    static func autoCapture(context: ModelContext, lightweight: Bool = false) async -> Outcome {
        let change = PasteboardWatch.currentChange()
        switch change {
        case .none:
            return .unchanged
        case .own:
            PasteboardWatch.markSeen(contentHash: nil)
            return .unchanged
        case .sameKind, .newKind:
            break
        }
        if AppGroup.sharedDefaults.bool(forKey: SettingsKeys.capturePaused) {
            // Lo copiado mientras tanto no entra al reanudar.
            PasteboardWatch.markSeen(contentHash: PasteboardWatch.lastMark?.contentHash)
            return .ignored
        }
        guard PasteboardWatch.shouldAutoRead(change, askMode: PasteboardWatch.askMode) else {
            return .waitingForUser
        }
        let reading = await readPasteboard(lightweight: lightweight)
        return ingest(reading, context: context, lightweight: lightweight)
    }

    /// Lee el portapapeles fuera del hilo principal.
    static func readPasteboard(lightweight: Bool) async -> PasteboardWatch.Reading {
        let images = AppGroup.sharedDefaults.object(forKey: SettingsKeys.saveImages) as? Bool ?? true
        // Más de 25 MB ya no cabe con holgura en la memoria del teclado.
        let maxBytes = lightweight ? 25_000_000 : 80_000_000
        return await Task.detached(priority: .userInitiated) {
            PasteboardWatch.read(images: images, maxImageBytes: maxBytes, decode: !lightweight)
        }.value
    }

    /// Guarda lo leído.
    ///
    /// Si es lo mismo que la última lectura no se toca el historial: iOS sube
    /// el contador del portapapeles sin que se copie nada, y antes eso volvía
    /// a subir al principio lo de siempre como si se acabara de copiar.
    ///
    /// - Parameter userInitiated: el usuario tocó Pegar. Entonces se guarda
    ///   aunque sea lo de la última vez (puede haberlo borrado del historial).
    @discardableResult
    static func ingest(_ reading: PasteboardWatch.Reading, context: ModelContext,
                       lightweight: Bool, userInitiated: Bool = false) -> Outcome {
        var isText = false
        if case .text = reading.content { isText = true }
        if let prompted = PasteboardWatch.promptEvidence(denied: reading.content == .denied,
                                                         seconds: reading.seconds,
                                                         isText: isText, isRemote: reading.isRemote) {
            PasteboardWatch.askMode = prompted
        }

        let previous = PasteboardWatch.lastMark?.contentHash
        func remember(_ hash: String?) {
            PasteboardWatch.lastMark = PasteboardMark(count: reading.count, signature: reading.signature,
                                                      contentHash: hash)
        }

        switch reading.content {
        case .denied:
            remember(previous)
            return .denied
        case .nothing:
            remember(nil)
            return .empty
        case .text(let text):
            let hash = HashService.sha256(text.trimmingCharacters(in: .whitespacesAndNewlines))
            remember(hash)
            if hash == previous, !userInitiated { return .unchanged }
            return saveText(text, context: context, lightweight: lightweight)
        case .image(let data):
            let hash = HashService.sha256(data)
            remember(hash)
            if hash == previous, !userInitiated { return .unchanged }
            return saveImage(data: data, size: ImageTools.pixelSize(of: data), context: context,
                             lightweight: lightweight)
        }
    }

    /// Lo que entrega el botón Pegar del sistema (`PasteButton`): iOS no
    /// pregunta porque el usuario lo tocó.
    @discardableResult
    static func save(pasted providers: [NSItemProvider], context: ModelContext) async -> Outcome {
        guard let provider = providers.first else { return .empty }
        let saveImages = AppGroup.sharedDefaults.object(forKey: SettingsKeys.saveImages) as? Bool ?? true

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            guard saveImages else { return .ignored }
            // El mismo formato que elegiría `PasteboardWatch.read`: así la
            // huella coincide con la de una captura automática.
            let type = PasteboardWatch.imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
                ?? UTType.image.identifier
            guard let data = await loadData(from: provider, type: type), !data.isEmpty else { return .empty }
            PasteboardWatch.markSeen(contentHash: HashService.sha256(data))
            return saveImage(data: data, size: ImageTools.pixelSize(of: data), context: context)
        }

        var text: String?
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            text = await loadURL(from: provider)?.absoluteString
        }
        if text == nil {
            text = await loadString(from: provider)
        }
        guard let text else { return .empty }
        PasteboardWatch.markSeen(contentHash: HashService.sha256(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        return saveText(text, context: context)
    }

    private static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    /// Completa lo que el teclado dejó pendiente: el OCR de las imágenes y la
    /// vista previa de los enlaces. Sólo debe llamarla la app.
    static func processPending(context: ModelContext) {
        let imageRaw = ClipContentType.image.rawValue
        let linkRaw = ClipContentType.link.rawValue
        let settled = Date.now.addingTimeInterval(-20)   // lo recién capturado ya lo procesa su propio guardado

        if AppGroup.sharedDefaults.object(forKey: SettingsKeys.ocrEnabled) as? Bool ?? true {
            var images = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.typeRaw == imageRaw && $0.recognizedText == nil && $0.createdAt < settled },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            images.fetchLimit = 6
            for item in (try? context.fetch(images)) ?? [] {
                guard let data = item.assetData else { continue }
                let itemID = item.id
                Task { @MainActor in
                    let text = await OCRService.recognizeText(in: data)
                    guard let found = findByID(itemID, context: context) else { return }
                    // Cadena vacía = ya se intentó y no había texto: no se repite.
                    found.recognizedText = text ?? ""
                    found.updatedAt = .now
                    try? context.save()
                }
            }
        }

        let recent = Date.now.addingTimeInterval(-3 * 86_400)
        var links = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.typeRaw == linkRaw && $0.linkTitle == nil && $0.createdAt < settled && $0.createdAt > recent },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        links.fetchLimit = 5
        for item in (try? context.fetch(links)) ?? [] {
            guard let text = item.urlString ?? item.plainText, let url = URL(string: text) else { continue }
            let itemID = item.id
            Task { @MainActor in
                let meta = await LinkMetadataService.fetch(for: url)
                guard let found = findByID(itemID, context: context) else { return }
                found.linkTitle = meta.title ?? ""     // vacío = intentado; `displayTitle` lo salta
                if found.previewImageData == nil { found.previewImageData = meta.imageData }
                found.updatedAt = .now
                try? context.save()
            }
        }
    }

    // MARK: Guardar texto / enlace

    @discardableResult
    static func saveText(_ text: String, sourceApp: String? = nil, context: ModelContext,
                         lightweight: Bool = false) -> Outcome {
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

        // Post-procesado asíncrono: metadatos del enlace (en el teclado no:
        // lo completa la app con `processPending`).
        if !lightweight, type == .link, let url = URL(string: trimmed) {
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
    static func saveImage(data: Data, size: CGSize, sourceApp: String? = nil, context: ModelContext,
                          lightweight: Bool = false) -> Outcome {
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

        // OCR en segundo plano (en el teclado no: Vision se come su memoria)
        if !lightweight, AppGroup.sharedDefaults.object(forKey: SettingsKeys.ocrEnabled) as? Bool ?? true {
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

// MARK: - Imágenes sin decodificarlas enteras
//
// Fuera de `CaptureService` (que vive en el hilo principal) porque el teclado
// hace las miniaturas en segundo plano.

enum ImageTools {
    /// Tamaño en píxeles leyendo sólo la cabecera de la imagen.
    static func pixelSize(of data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return .zero }
        return CGSize(width: width, height: height)
    }

    /// Tipo (UTI) de la imagen según su cabecera, para copiarla tal cual.
    static func typeIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }

    /// Miniatura sin decodificar la imagen completa: ImageIO la reduce al
    /// vuelo, así que una captura de 12 MP no pasa nunca por memoria entera.
    static func thumbnail(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}
