import Foundation
import SwiftData

/// Identificador del App Group compartido entre la app y sus extensiones.
/// Cámbialo junto con los bundle IDs en project.yml si usas otro prefijo.
enum AppGroup {
    static let preferredID = "group.com.emilio.clipdeck"

    /// Los certificados de firma de pago suelen reescribir los App Groups a IDs
    /// propios del equipo firmante. Sondeamos candidatos y usamos el primero
    /// que el sistema nos conceda.
    static let candidateIDs: [String] = [preferredID] + (1...5).map { "group.1339403ddeb57d8b.\($0)" }

    static let resolvedID: String? = candidateIDs.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    /// URL del contenedor compartido. Si ningún App Group está aprovisionado,
    /// se usa Application Support local (la app funciona, sin compartir datos).
    static var containerURL: URL {
        if let id = resolvedID,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Instancia única: `KbPrefs` la consulta en cada pulsación de tecla, y
    /// `UserDefaults(suiteName:)` construye un objeto nuevo en cada llamada.
    static let sharedDefaults: UserDefaults = {
        if let id = resolvedID, let defaults = UserDefaults(suiteName: id) {
            return defaults
        }
        return .standard
    }()
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
///
/// Viven en el App Group, no en `UserDefaults.standard`: dentro de una
/// extensión `.standard` es un sandbox distinto, así que el teclado y la Share
/// Extension nunca verían lo que el usuario configuró en la app.
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

    private static let migratedFlag = "settings.migratedToAppGroup"

    static let all = [capturePaused, moveReusedToTop, confirmDelete, saveImages,
                      ocrEnabled, sensitiveDetection, faceIDLock, blurInSwitcher,
                      retentionDays, appearance, hasOnboarded]

    /// Copia una sola vez los ajustes que quedaron en `UserDefaults.standard`
    /// de la app al App Group. Sólo debe llamarla la app, nunca una extensión.
    @discardableResult
    static func migrateToSharedStoreIfNeeded() -> Bool {
        let shared = AppGroup.sharedDefaults
        guard shared !== UserDefaults.standard,
              !shared.bool(forKey: migratedFlag) else { return false }
        for key in all {
            if let value = UserDefaults.standard.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
        shared.set(true, forKey: migratedFlag)
        return true
    }
}
