import Foundation
import SwiftData

/// Identificador del App Group compartido entre la app y sus extensiones.
/// Cámbialo junto con los bundle IDs en project.yml si usas otro prefijo.
enum AppGroup {
    static let id = "group.com.emilio.clipdeck"

    /// URL del contenedor compartido. Si el App Group no está aprovisionado
    /// (p. ej. durante pruebas sin firma), se usa Application Support local.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }
}

enum ClipStore {
    static let schema = Schema([ClipItem.self, Pinboard.self, CaptureRule.self])

    static func makeContainer() -> ModelContainer {
        let url = AppGroup.containerURL.appendingPathComponent("ClipDeck.store")
        do {
            let config = ModelConfiguration(schema: schema, url: url)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Último recurso: contenedor en memoria para no bloquear la app.
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }
    }
}

/// Claves de ajustes de usuario.
enum SettingsKeys {
    static let capturePaused        = "settings.capturePaused"
    static let moveReusedToTop      = "settings.moveReusedToTop"
    static let confirmDelete        = "settings.confirmDelete"
    static let saveImages           = "settings.saveImages"
    static let ocrEnabled           = "settings.ocrEnabled"
    static let sensitiveDetection   = "settings.sensitiveDetection"
    static let faceIDLock           = "settings.faceIDLock"
    static let blurInSwitcher       = "settings.blurInSwitcher"
    static let retentionDays        = "settings.retentionDays"   // 0 = ilimitado
    static let appearance           = "settings.appearance"       // system | light | dark
    static let hasOnboarded         = "settings.hasOnboarded"
    static let lastPasteboardChange = "capture.lastChangeCount"
}
