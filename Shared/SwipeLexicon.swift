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

    /// Vocabulario ya armado, inmutable.
    ///
    /// El corrector y el reconocedor de trazos lo leen desde otros hilos
    /// mientras la carga puede seguir en marcha. Antes los arrays se rellenaban
    /// en su sitio y `isLoaded` ya decía que sí con la primera palabra: una
    /// palabra corregida en el primer segundo recorría arrays a medio crecer
    /// (y de distinto largo entre sí), lo que podía tumbar el teclado. Ahora se
    /// construye aparte y se publica de una sola vez.
    struct Snapshot {
        let words: [String]
        let flat: [UInt8]
        let starts: [Int32]
        let lens: [UInt8]
        let masks: [UInt32]
        let priors: [UInt8]
        /// true si se pudo cargar el diccionario del sistema (no sólo el mínimo).
        let hasSystemWords: Bool
        /// Palabra sin tildes (como se teclea) → índice de la más probable.
        /// Sólo las frecuentes: sirve para separar palabras pegadas.
        let index: [String: Int32]
        /// Las frecuentes que pierden su forma tecleada ante otra más usada
        /// («anos» ante «años», «mas» ante «más»), con su prior.
        let rivals: [String: UInt8]

        var count: Int { words.count }

        /// Prior de una palabra frecuente, o nil si no está entre las frecuentes.
        func prior(of word: String, folded: String) -> UInt8? {
            if let hit = lookup(folded: folded), hit.word == word { return hit.prior }
            return rivals[word]
        }

        /// La palabra más probable que se teclea así («estas» → «estás» o
        /// «estas», la que más se use).
        func lookup(folded: String) -> (word: String, prior: UInt8)? {
            guard let i = index[folded] else { return nil }
            return (words[Int(i)], priors[Int(i)])
        }
    }

    /// Prior mínimo para entrar en `Snapshot.index`.
    static let indexedPrior: UInt8 = 100

    /// Texto con las letras de las teclas («canción» → «cancion»).
    static func folded(_ keys: [UInt8]) -> String {
        String(keys.map { SwipeAlphabet.letters[Int($0)] })
    }

    private var current: Snapshot?
    /// Protege `current`. Se retiene sólo un instante: nunca durante la carga.
    private let stateLock = NSLock()
    /// Serializa las cargas (que sí tardan).
    private let loadLock = NSLock()

    /// Vocabulario publicado, o nil mientras no termine de cargarse.
    var snapshot: Snapshot? {
        stateLock.lock(); defer { stateLock.unlock() }
        return current
    }

    var isLoaded: Bool { snapshot != nil }
    var count: Int { snapshot?.count ?? 0 }
    var hasSystemWords: Bool { snapshot?.hasSystemWords ?? false }

    // MARK: Construcción en memoria

    private struct Builder {
        var words: [String] = []
        var flat: [UInt8] = []
        var starts: [Int32] = []
        var lens: [UInt8] = []
        var masks: [UInt32] = []
        var priors: [UInt8] = []
        var seen = Set<String>()
        var trackSeen = true
        var hasSystemWords = false

        mutating func add(_ raw: String, prior: UInt8) {
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

        func finish() -> Snapshot {
            var index: [String: Int32] = [:]
            var keys: [Int: String] = [:]
            for i in words.indices where priors[i] >= SwipeLexicon.indexedPrior {
                let s = Int(starts[i])
                let key = SwipeLexicon.folded(Array(flat[s..<(s + Int(lens[i]))]))
                keys[i] = key
                if let old = index[key], priors[Int(old)] >= priors[i] { continue }
                index[key] = Int32(i)
            }
            var rivals: [String: UInt8] = [:]
            for (i, key) in keys where index[key] != Int32(i) { rivals[words[i]] = priors[i] }
            return Snapshot(words: words, flat: flat, starts: starts, lens: lens, masks: masks,
                            priors: priors, hasSystemWords: hasSystemWords, index: index, rivals: rivals)
        }
    }

    /// Vocabulario armado a partir de una lista (pruebas).
    static func makeSnapshot(_ entries: [(word: String, prior: UInt8)]) -> Snapshot {
        var builder = Builder()
        for e in entries { builder.add(e.word, prior: e.prior) }
        return builder.finish()
    }

    /// Prior según el puesto en una lista de frecuencia de uso: lo más usado
    /// pesa más, con caída logarítmica (la 100 y la 200 apenas se distinguen;
    /// la 10 y la 10000, mucho).
    static func frequencyPrior(rank: Int, top: Double, floor: Double) -> UInt8 {
        let value = top - 13 * log(Double(max(rank, 1)))
        return UInt8(min(max(value, floor), top))
    }

    /// Lista de frecuencia incluida en el teclado (una palabra por línea, de
    /// la más usada a la menos). Fuera del teclado no está y no se usa.
    private static func frequencyList(_ name: String) -> [String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Carga el vocabulario en memoria. Pesado: llamar en segundo plano.
    func load() {
        loadLock.lock(); defer { loadLock.unlock() }
        guard !isLoaded else { return }
        var builder = Builder()

        // 1. Vocabulario propio del usuario (lo usado una sola vez puede ser
        //    una errata: no entra hasta que se repite).
        for (w, c) in WordLearner.learnedWords() where c >= WordLearner.minUses {
            builder.add(w, prior: UInt8(min(200 + c * 4, 255)))
        }
        // 2. Frecuencia de uso real (subtítulos, filtrada con diccionario: sin
        //    nombres propios). Antes el orden lo daba la posición en los
        //    completados del sistema, que no dice qué palabra se usa más, y el
        //    corrector elegía entre candidatas casi a ciegas.
        for (i, w) in Self.frequencyList("frecuencias-es").enumerated() {
            builder.add(w, prior: Self.frequencyPrior(rank: i + 1, top: 230, floor: 100))
        }
        for (i, w) in Self.frequencyList("frecuencias-en").enumerated() {
            builder.add(w, prior: Self.frequencyPrior(rank: i + 1, top: 195, floor: 80))
        }
        // 3. Palabras de uso diario (si no venían ya en las listas).
        for w in KbData.commonWords { builder.add(w, prior: 190) }

        // 4. Diccionario del sistema recolectado por la app. Se recorre por
        //    bytes: convertir 800 KB a String y recorrerlo carácter a carácter
        //    era mucho más lento que separar por saltos de línea en crudo.
        builder.trackSeen = false
        if let data = try? Data(contentsOf: Self.fileURL), !data.isEmpty {
            builder.hasSystemWords = true
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
                builder.add(word, prior: UInt8(min(max(value, 5), 180)))
            }
        }
        builder.seen = []

        let built = builder.finish()
        stateLock.lock()
        current = built
        stateLock.unlock()
    }

    /// Descarta lo cargado: la próxima carga incorpora las palabras aprendidas
    /// sin tocar lo que otro hilo esté leyendo (se queda con su copia).
    func invalidate() {
        stateLock.lock()
        current = nil
        stateLock.unlock()
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