import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

// MARK: - Cuándo leer el portapapeles
//
// Leer lo copiado es lo que hace que iOS pregunte «¿Permitir pegar?». Antes se
// leía cada vez que cambiaba `changeCount`, pero iOS lo cambia solo: lo sube
// dos veces cada vez que un campo de texto toma el foco (desde iOS 13), y
// también al volver de otra app o con el portapapeles universal. Así el aviso
// salía a cada rato y lo de siempre volvía a subir al principio del historial
// como si se hubiera copiado otra vez.
//
// Ahora, antes de leer, se mira sólo lo que iOS deja ver sin avisar —cuántos
// elementos hay y de qué tipos— y se compara con la última vez.

/// Qué pasó con el portapapeles desde la última vez que ClipDeck lo miró.
enum PasteboardChange: Equatable {
    /// Nada.
    case none
    /// Cambió el contador, pero hay los mismos tipos que la última vez: puede
    /// ser algo nuevo o lo mismo de antes.
    case sameKind
    /// Hay otros tipos: seguro que se copió algo nuevo.
    case newKind
    /// Lo copió ClipDeck desde su historial: ya está guardado.
    case own
}

/// Lo último que ClipDeck sabe del portapapeles. Lo comparten la app y el
/// teclado a través del App Group.
struct PasteboardMark: Equatable {
    var count: Int
    /// Número de elementos y sus tipos (`PasteboardWatch.signature`).
    var signature: String
    /// Huella de lo último que se leyó.
    var contentHash: String?
}

/// Lo que el teclado vio del portapapeles la última vez que lo miró, sin
/// leerlo: el contador y los tipos (`PasteboardWatch.signature`).
struct PasteboardSighting: Equatable {
    var count: Int
    var signature: String
}

enum PasteboardWatch {

    /// Tipo propio que ClipDeck añade a lo que copia. Ninguna app lo entiende,
    /// así que no cambia lo que se pega; sirve para saber, sin leer nada, que
    /// eso ya está en el historial.
    static let ownType = "com.emilio.clipdeck.copied"
    /// Lo que llega de otro dispositivo (portapapeles universal).
    static let remoteType = "com.apple.is-remote-clipboard"

    static let signatureKey = "capture.lastSignature"
    static let hashKey = "capture.lastContentHash"
    /// La app y el teclado llevan la cuenta por separado: iOS puede preguntar
    /// a uno y no al otro, y la app no debe dejar de capturar por el teclado.
    static let askModeKey = "capture.askMode"
    static let keyboardAskModeKey = "capture.askMode.keyboard"
    /// El usuario cerró la explicación de la app sobre «Pegar desde otras apps».
    static let askTipDismissedKey = "capture.askTipDismissed"

    // MARK: Decisiones

    static func signature(itemCount: Int, types: [String]) -> String {
        "\(itemCount)|" + types.sorted().joined(separator: ",")
    }

    static func classify(count: Int, itemCount: Int, types: [String],
                         last: PasteboardMark?) -> PasteboardChange {
        if let last, last.count == count { return .none }
        if types.contains(ownType) { return .own }
        guard let last, !last.signature.isEmpty else { return .newKind }
        return signature(itemCount: itemCount, types: types) == last.signature ? .sameKind : .newKind
    }

    /// ¿Pudo cambiar lo copiado entre dos vistazos? Cada vez que un campo de
    /// texto toma el foco, iOS sube el contador de dos en dos sin tocar lo
    /// copiado: escribe y borra una imagen para ver si se pueden pegar Memojis
    /// (desde iOS 13; developer.apple.com/forums/thread/131419). Una copia lo
    /// sube de uno en uno. Con los mismos tipos y una subida par, lo copiado
    /// es lo de antes, y leerlo sólo sacaría el aviso de iOS. Dos copias
    /// seguidas sin mirar entre medias también suben dos, pero es raro, y lo
    /// último copiado lo recoge igual el panel al abrirse.
    static func contentMayHaveChanged(from old: PasteboardSighting?, to new: PasteboardSighting) -> Bool {
        guard let old else { return true }
        guard new.count != old.count else { return false }
        if new.signature != old.signature { return true }
        let rise = new.count - old.count
        return rise < 0 || rise % 2 != 0
    }

    /// ¿Leer sin que el usuario lo pida? Con «Pegar desde otras apps» en
    /// Preguntar cada lectura saca la alerta, así que entonces sólo se lee
    /// cuando el usuario toca Pegar.
    static func shouldAutoRead(_ change: PasteboardChange, askMode: Bool) -> Bool {
        switch change {
        case .none, .own: return false
        case .sameKind, .newKind: return !askMode
        }
    }

    /// Qué dice una lectura sobre si iOS pregunta antes de pegar: `true` si
    /// preguntó (no dio el contenido, o tardó lo que tarda una persona en
    /// tocar un botón), `false` si leyó al instante, `nil` si no se sabe. Las
    /// imágenes y lo que llega de otro dispositivo tardan por sí mismos, así
    /// que su tiempo no cuenta.
    static func promptEvidence(denied: Bool, seconds: TimeInterval,
                               isText: Bool, isRemote: Bool) -> Bool? {
        if denied { return true }
        guard isText, !isRemote else { return nil }
        if seconds >= 0.6 { return true }
        if seconds <= 0.15 { return false }
        return nil
    }

    // MARK: Estado compartido

    private static var defaults: UserDefaults { AppGroup.sharedDefaults }

    static var lastMark: PasteboardMark? {
        get {
            guard defaults.object(forKey: SettingsKeys.lastPasteboardChange) != nil else { return nil }
            return PasteboardMark(count: defaults.integer(forKey: SettingsKeys.lastPasteboardChange),
                                  signature: defaults.string(forKey: signatureKey) ?? "",
                                  contentHash: defaults.string(forKey: hashKey))
        }
        set {
            guard let mark = newValue else {
                for key in [SettingsKeys.lastPasteboardChange, signatureKey, hashKey] {
                    defaults.removeObject(forKey: key)
                }
                return
            }
            defaults.set(mark.count, forKey: SettingsKeys.lastPasteboardChange)
            defaults.set(mark.signature, forKey: signatureKey)
            if let hash = mark.contentHash {
                defaults.set(hash, forKey: hashKey)
            } else {
                defaults.removeObject(forKey: hashKey)
            }
        }
    }

    /// iOS pregunta antes de cada lectura: «Pegar desde otras apps» está en
    /// Preguntar, o el usuario tocó «No permitir».
    static var askMode: Bool {
        get { defaults.bool(forKey: ownAskModeKey) }
        set { defaults.set(newValue, forKey: ownAskModeKey) }
    }

    private static let ownAskModeKey =
        Bundle.main.bundleURL.pathExtension == "appex" ? keyboardAskModeKey : askModeKey

    #if canImport(UIKit)

    // MARK: Mirar sin leer

    /// Lo que iOS deja ver sin avisar al usuario.
    struct Peek {
        let count: Int
        let itemCount: Int
        /// Tipos del primer elemento.
        let types: [String]

        var signature: String { PasteboardWatch.signature(itemCount: itemCount, types: types) }
    }

    static func peek(_ pasteboard: UIPasteboard = .general) -> Peek {
        Peek(count: pasteboard.changeCount, itemCount: pasteboard.numberOfItems, types: pasteboard.types)
    }

    static func currentChange(_ pasteboard: UIPasteboard = .general) -> PasteboardChange {
        let p = peek(pasteboard)
        return classify(count: p.count, itemCount: p.itemCount, types: p.types, last: lastMark)
    }

    /// Da por visto lo que hay ahora, sin leerlo.
    static func markSeen(contentHash: String?) {
        let p = peek()
        lastMark = PasteboardMark(count: p.count, signature: p.signature, contentHash: contentHash)
    }

    // MARK: Copiar

    /// Copia con la marca de ClipDeck: aunque iOS suba el contador, eso no
    /// vuelve a leerse ni entra otra vez al historial.
    static func copy(_ representations: [String: Any]) {
        var item = representations
        item[ownType] = Data("1".utf8)
        UIPasteboard.general.setItems([item], options: [:])
        markSeen(contentHash: nil)
    }

    static func copy(text: String) {
        copy([UTType.utf8PlainText.identifier: text])
    }

    // MARK: Leer

    enum Content: Equatable, Sendable {
        case text(String)
        case image(Data)
        /// Nada que guardar: vacío, imágenes desactivadas o demasiado grande.
        case nothing
        /// Había algo, pero iOS no lo dio: el usuario tocó «No permitir».
        case denied
    }

    struct Reading: Sendable {
        let content: Content
        let count: Int
        let signature: String
        let seconds: TimeInterval
        let isRemote: Bool
    }

    /// Por orden: la animación de un GIF y luego sin pérdida antes que con ella.
    static let imageTypes = [UTType.gif, .png, .jpeg, .heic, .tiff].map(\.identifier)

    /// Lee lo copiado. Se queda esperando mientras iOS pregunta «¿Permitir
    /// pegar?» o mientras llega lo copiado en otro dispositivo: nunca en el
    /// hilo principal.
    ///
    /// - Parameters:
    ///   - images: si se guardan imágenes (si no, ni se leen).
    ///   - maxImageBytes: una imagen más grande no se guarda.
    ///   - decode: si la imagen no viene en un formato conocido, decodificarla.
    ///     En el teclado no: no le alcanza la memoria.
    static func read(images: Bool, maxImageBytes: Int, decode: Bool) -> Reading {
        let pasteboard = UIPasteboard.general
        let p = peek(pasteboard)
        let start = CFAbsoluteTimeGetCurrent()
        var content = Content.nothing
        if pasteboard.hasImages {
            if images {
                content = readImage(pasteboard, types: p.types, maxBytes: maxImageBytes, decode: decode)
            }
        } else if p.types.contains(UTType.url.identifier) {
            // Un solo intento: si iOS no lo dio, pedir también el texto
            // volvería a preguntar.
            if let url = pasteboard.url {
                content = .text(url.absoluteString)
            } else {
                content = .denied
            }
        } else if pasteboard.hasStrings {
            if let text = pasteboard.string {
                content = .text(text)
            } else {
                content = .denied
            }
        }
        return Reading(content: content, count: p.count, signature: p.signature,
                       seconds: CFAbsoluteTimeGetCurrent() - start,
                       isRemote: p.types.contains(remoteType))
    }

    /// Los bytes tal como están, sin decodificar: así la app y el teclado
    /// sacan la misma huella de la misma imagen y no se guarda dos veces.
    private static func readImage(_ pasteboard: UIPasteboard, types: [String],
                                  maxBytes: Int, decode: Bool) -> Content {
        if let type = imageTypes.first(where: { types.contains($0) }) {
            guard let data = pasteboard.data(forPasteboardType: type), !data.isEmpty else { return .denied }
            return data.count <= maxBytes ? .image(data) : .nothing
        }
        guard decode else { return .nothing }
        guard let image = pasteboard.image else { return .denied }
        guard let data = image.jpegData(compressionQuality: 0.9), data.count <= maxBytes else { return .nothing }
        return .image(data)
    }

    #endif
}
