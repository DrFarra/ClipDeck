import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Extensión de compartir: guarda texto, enlaces, imágenes y archivos
/// en el historial compartido de ClipDeck.
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        statusLabel.text = "Guardando en ClipDeck…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            statusLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20)
        ])

        processAttachments()
    }

    private func processAttachments() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        guard !providers.isEmpty else {
            finish(message: "Nada que guardar")
            return
        }

        let group = DispatchGroup()
        var savedCount = 0
        let lock = NSLock()

        func markSaved() {
            lock.lock(); savedCount += 1; lock.unlock()
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let url = item as? URL {
                        if url.isFileURL {
                            if let data = try? Data(contentsOf: url) {
                                self.save { CaptureService.saveFile(data: data, fileName: url.lastPathComponent, sourceApp: "Compartir", context: $0) }
                                markSaved()
                            }
                        } else {
                            self.save { CaptureService.saveText(url.absoluteString, sourceApp: "Compartir", context: $0) }
                            markSaved()
                        }
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                    var data: Data?
                    var size = CGSize.zero
                    if let url = item as? URL, let d = try? Data(contentsOf: url) { data = d }
                    else if let d = item as? Data { data = d }
                    else if let image = item as? UIImage { data = image.jpegData(compressionQuality: 0.9); size = image.size }
                    if let data {
                        if size == .zero, let image = UIImage(data: data) { size = image.size }
                        let s = size
                        self.save { CaptureService.saveImage(data: data, size: s, sourceApp: "Compartir", context: $0) }
                        markSaved()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    if let text = item as? String {
                        self.save { CaptureService.saveText(text, sourceApp: "Compartir", context: $0) }
                        markSaved()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let url = item as? URL, let data = try? Data(contentsOf: url) {
                        self.save { CaptureService.saveFile(data: data, fileName: url.lastPathComponent, sourceApp: "Compartir", context: $0) }
                        markSaved()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            self.finish(message: savedCount > 0 ? "Guardado en ClipDeck ✓" : "No se pudo guardar")
        }
    }

    /// Ejecuta una operación de guardado en el hilo principal con un contexto propio.
    private func save(_ operation: @escaping @MainActor (ModelContext) -> Void) {
        let work = {
            let container = ClipStore.makeContainer()
            let context = ModelContext(container)
            MainActor.assumeIsolated {
                operation(context)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func finish(message: String) {
        statusLabel.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
