import Foundation
import CryptoKit
import UIKit
import Vision
import LinkPresentation
import UniformTypeIdentifiers
import WidgetKit

// MARK: - Hash

enum HashService {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }
}

// MARK: - OCR (Vision)

enum OCRService {
    static func recognizeText(in imageData: Data) async -> String? {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["es-ES", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .utility).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Metadatos de enlaces

enum LinkMetadataService {
    struct Result {
        var title: String?
        var imageData: Data?
    }

    @MainActor
    static func fetch(for url: URL) async -> Result {
        let provider = LPMetadataProvider()
        provider.timeout = 12
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else {
            return Result()
        }
        var imageData: Data?
        if let imageProvider = metadata.imageProvider {
            imageData = await withCheckedContinuation { continuation in
                _ = imageProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }
        return Result(title: metadata.title, imageData: imageData)
    }
}

// MARK: - Snapshot para el widget

enum WidgetSnapshot {
    static let lastTitleKey = "widget.lastTitle"
    static let lastTypeKey = "widget.lastType"
    static let countKey = "widget.count"

    static func update(lastTitle: String?, lastType: String?, count: Int) {
        let defaults = AppGroup.sharedDefaults
        defaults.set(lastTitle, forKey: lastTitleKey)
        defaults.set(lastType, forKey: lastTypeKey)
        defaults.set(count, forKey: countKey)
        // Sin esto el widget sólo se refrescaría con su propia política de 30 min.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
