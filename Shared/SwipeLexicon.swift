import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Alfabeto del teclado (27 letras) y plegado de acentos
//
// Para reconocer un trazo hace falta traducir cada palabra a la secuencia de
// teclas que habría que tocar. "también" se recorre por t-a-m-b-i-e-n, pero se
// escribe con su tilde: por eso se guarda la palabra original y aparte su
// versión "plegada" a teclas reales. La ñ tiene tecla propia, así que no se
// pliega a n.

enum SwipeAlphabet {
    static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyzñ")
    static let count = 27

    private static let table: [Character: UInt8] = {
        var t: [Character: UInt8] = [:]
        for (i, c) in letters.enumerated() { t[c] = UInt8(i) }
        let folds: [Character: Character] = [
            "á": "a", "à": "a", "â": "a", "ä": "a", "ã": "a", "å": "a",
            "é": "e", "è": "e", "ê": "e", "ë": "e",
            "í": "i", "ì": "i", "î": "i", "ï": "i",
            "ó": "o", "ò": "o", "ô": "o", "ö": "o", "õ": "o",
            "ú": "u", "ù": "u", "û": "u", "ü": "u",
            "ç": "c", "ý": "y", "ÿ": "y"
        ]
        for (k, v) in folds { t[k] = t[v] }
        return t
    }()

    static func index(_ c: Character) -> UInt8? { table[c] }

    /// Secuencia de teclas de una palabra. nil si contiene algo no tecleable.
    static func encode(_ word: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(word.count)
        for c in word.lowercased() {
            guard let i = table[c] else { return nil }
            out.append(i)
        }
        return out
    }
}

// MARK: - Vocabulario para escritura deslizando
//
// No se incluye ninguna lista de palabras en la app: el vocabulario se arma en
// el dispositivo a partir de tres fuentes.
//   1. Palabras que el usuario ya escribió (WordLearner), con máxima prioridad.
//   2. Palabras muy frecuentes de uso diario.
//   3. El diccionario del sistema, recolectado una sola vez por la app
//      pidiéndole a UITextChecker los completados de cada prefijo de dos letras
//      y guardando el resultado en el App Group.
//
// En memoria se guarda de forma compacta (arrays planos y una máscara de bits
// por palabra) para poder descartar decenas de miles de candidatos con una
// sola operación entera por palabra.

final class SwipeLexicon {

    static let shared = SwipeLexicon()

    static let fileName = "swipe-lexicon-v1.tsv"
    static let countKey = "kb.swipeLexiconCount"
    static let dateKey  = "kb.swipeLexiconDate"
    static let progressKey = "kb.swipeLexiconProgress"

    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent(fileName) }
    static var isBuilt: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    static var builtCount: Int { KbPrefs.store.integer(forKey: countKey) }
    static var builtDate: Date? { KbPrefs.store.object(forKey: dateKey) as? Date }
    /// ¿Se recorrió ya todo el alfabeto?
    static var isComplete: Bool {
        KbPrefs.store.integer(forKey: progressKey) >= SwipeAlphabet.count && builtCount > 200
    }

    private(set) var words: [String] = []
    private(set) var flat: [UInt8] = []
    private(set) var starts: [Int32] = []
    private(set) var lens: [UInt8] = []
    private(set) var masks: [UInt32] = []
    private(set) var priors: [UInt8] = []
    /// true si se pudo cargar el diccionario del sistema (no sólo el mínimo).
    private(set) var hasSystemWords = false

    var count: Int { words.count }
    var isLoaded: Bool { !words.isEmpty }

    private var seen = Set<String>()
    private var trackSeen = true
    private let lock = NSLock()

    // MARK: Construcción en memoria

    private func reset() {
        words.removeAll(); flat.removeAll(); starts.removeAll()
        lens.removeAll(); masks.removeAll(); priors.removeAll()
        seen.removeAll(); trackSeen = true; hasSystemWords = false
    }

    private func add(_ raw: String, prior: UInt8) {
        let w = raw.lowercased()
        guard w.count >= 2, w.count <= 18 else { return }
        if trackSeen {
            if seen.contains(w) { return }
            seen.insert(w)
        } else if seen.contains(w) {
            return
        }
        guard let enc = SwipeAlphabet.encode(w) else { return }
        var mask: UInt32 = 0
        for i in enc { mask |= (UInt32(1) << UInt32(i)) }
        starts.append(Int32(flat.count))
        flat.append(contentsOf: enc)
        lens.append(UInt8(enc.count))
        masks.append(mask)
        priors.append(prior)
        words.append(w)
    }

    /// Carga el vocabulario en memoria. Pesado: llamar en segundo plano.
    func load() {
        lock.lock(); defer { lock.unlock() }
        guard !isLoaded else { return }
        reset()

        // 1. Vocabulario propio del usuario.
        for (w, c) in WordLearner.learnedWords() {
            add(w, prior: UInt8(min(200 + c * 4, 255)))
        }
        // 2. Palabras de uso diario.
        for w in KbData.commonWords { add(w, prior: 190) }

        // 3. Diccionario del sistema recolectado por la app. Se recorre por
        //    bytes: convertir 800 KB a String y recorrerlo carácter a carácter
        //    era mucho más lento que separar por saltos de línea en crudo.
        trackSeen = false
        if let data = try? Data(contentsOf: Self.fileURL), !data.isEmpty {
            hasSystemWords = true
            let newline = UInt8(ascii: "\n")
            let tab = UInt8(ascii: "\t")
            for line in data.split(separator: newline, omittingEmptySubsequences: true) {
                guard let tabIndex = line.firstIndex(of: tab) else { continue }
                let wordBytes = line[line.startIndex..<tabIndex]
                guard !wordBytes.isEmpty,
                      let word = String(data: Data(wordBytes), encoding: .utf8) else { continue }
                var value = 0
                for b in line[line.index(after: tabIndex)...] where b >= 48 && b <= 57 {
                    value = value * 10 + Int(b - 48)
                }
                add(word, prior: UInt8(min(max(value, 5), 180)))
            }
        }
        seen = []
    }

    /// Vuelve a incorporar las palabras aprendidas sin releer todo el archivo.
    func invalidate() {
        lock.lock()
        let wasLoaded = isLoaded
        if wasLoaded { reset() }
        lock.unlock()
    }

    // MARK: Recolección del diccionario del sistema (se ejecuta en la app)

    #if canImport(UIKit)
    /// Recolecta el diccionario del sistema pidiéndole a UITextChecker los
    /// completados de cada prefijo de dos letras.
    ///
    /// Es lento (puede pasar del minuto), así que se hace por bloques: uno por
    /// letra inicial. Cada bloque se anexa al archivo y se anota el avance, de
    /// modo que si iOS suspende la app el trabajo hecho no se pierde y la
    /// siguiente vez continúa donde iba. Como los completados de "ca" siempre
    /// empiezan por "c", ningún bloque puede repetir palabras de otro.
    @discardableResult
    static func build(restart: Bool = false,
                      languages: [String] = ["es_ES", "en_US"],
                      progress: ((Double) -> Void)? = nil) -> Int {

        let checker = UITextChecker()
        let available = Set(UITextChecker.availableLanguages)
        var langs = languages.filter { available.contains($0) }
        if langs.isEmpty {
            langs = available.contains("en_US") ? ["en_US"] : Array(available.prefix(1))
        }
        guard !langs.isEmpty else { return 0 }

        let alphabet = SwipeAlphabet.letters
        var from = restart ? 0 : KbPrefs.store.integer(forKey: progressKey)
        if from >= alphabet.count || from < 0 { from = 0 }

        var total = KbPrefs.store.integer(forKey: countKey)
        if from == 0 {
            total = 0
            try? FileManager.default.removeItem(at: fileURL)
        }

        for li in from..<alphabet.count {
            var chunk: [String: Int] = [:]
            for b in alphabet {
                let prefix = String([alphabet[li], b])
                let range = NSRange(location: 0, length: prefix.utf16.count)
                for lang in langs {
                    guard let list = checker.completions(forPartialWordRange: range,
                                                         in: prefix, language: lang) else { continue }
                    for (i, raw) in list.prefix(200).enumerated() {
                        let w = raw.lowercased()
                        guard w.count >= 3, w.count <= 18,
                              SwipeAlphabet.encode(w) != nil else { continue }
                        let pos = min(i, 300)
                        if let old = chunk[w] {
                            if pos < old { chunk[w] = pos }
                        } else {
                            chunk[w] = pos
                        }
                    }
                }
            }

            if !chunk.isEmpty {
                var text = String()
                text.reserveCapacity(chunk.count * 14)
                for (w, pos) in chunk {
                    text += w
                    text += "\t"
                    text += String(max(10, 90 - pos))
                    text += "\n"
                }
                appendToFile(text)
                total += chunk.count
            }

            KbPrefs.store.set(li + 1, forKey: progressKey)
            KbPrefs.store.set(total, forKey: countKey)
            progress?(Double(li + 1) / Double(alphabet.count))
        }

        KbPrefs.store.set(Date(), forKey: dateKey)
        return total
    }

    private static func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Lanza la recolección en segundo plano si está incompleta.
    static func buildIfNeeded(completion: ((Int) -> Void)? = nil) {
        if isComplete { completion?(builtCount); return }
        DispatchQueue.global(qos: .utility).async {
            let n = build()
            DispatchQueue.main.async { completion?(n) }
        }
    }
    #endif
}