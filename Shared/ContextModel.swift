import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Modelo de contexto: qué palabra es probable detrás de la anterior.
///
/// Es lo que hace que un teclado como SwiftKey proponga la siguiente palabra
/// antes de teclearla y elija bien entre candidatas parecidas. P(palabra |
/// anterior) mezcla, de más a menos fuerte:
///
///   1. Lo que escribe el usuario (bigramas de `WordLearner`), con peso triple.
///   2. Bigramas de partida, sacados de frases de uso diario incluidas en el
///      teclado (`frases-es.txt`, `frases-en.txt`): así no empieza en blanco.
///   3. Lo frecuente que es la palabra sola (el prior del vocabulario).
///
/// Interpolado: λ·P(bigrama) + (1 − λ)·P(palabra).
enum ContextModel {

    /// Contexto de la primera palabra de una frase.
    static let sentenceStart = "^"
    static let lambda = 0.6
    static let learnedWeight = 3

    /// Bigramas: palabra anterior → palabra siguiente → veces.
    struct Bigrams {
        var next: [String: [String: Int]] = [:]
        var totals: [String: Int] = [:]

        mutating func add(_ previous: String, _ word: String, _ count: Int = 1) {
            next[previous, default: [:]][word, default: 0] += count
            totals[previous, default: 0] += count
        }
    }

    /// Palabras de un texto, en minúsculas (con su apóstrofo: «don't»).
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0 == "'" || $0 == "’") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    /// Bigramas de unas frases (cortadas en . ! ? y saltos de línea).
    static func bigrams(fromCorpus text: String) -> Bigrams {
        var b = Bigrams()
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            var previous = sentenceStart
            for w in tokens(String(sentence)) {
                b.add(previous, w)
                previous = w
            }
        }
        return b
    }

    private static let lock = NSLock()
    private static var loaded: Bigrams?

    /// Bigramas de partida del teclado. Fuera de él (la app, las pruebas) no
    /// están los archivos y quedan vacíos.
    static var builtIn: Bigrams {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        var text = ""
        for name in ["frases-es", "frases-en"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "txt"),
               let t = try? String(contentsOf: url, encoding: .utf8) {
                text += t + "\n"
            }
        }
        let b = bigrams(fromCorpus: text)
        loaded = b
        return b
    }

    /// P(palabra) a partir del prior del vocabulario (230 − 13·ln(puesto)):
    /// más o menos 1 / (puesto · 11).
    static func unigram(prior: UInt8?) -> Double {
        guard let prior else { return 1e-7 }
        return min(exp((Double(prior) - 230) / 13) / 11, 0.2)
    }

    /// Todo lo que se sabe de lo que sigue a una palabra concreta.
    struct Context {
        let previous: String
        private let counts: [String: Int]
        private let total: Int

        /// `previous` vacío = inicio de frase. `learned`: bigramas del usuario
        /// que empiezan por esa palabra (`WordLearner.successorCounts`).
        init(previous: String, learned: [String: Int], builtIn: Bigrams = ContextModel.builtIn) {
            let p = previous.isEmpty ? ContextModel.sentenceStart : previous.lowercased()
            self.previous = p
            var counts = builtIn.next[p] ?? [:]
            for (w, c) in learned { counts[w.lowercased(), default: 0] += c * ContextModel.learnedWeight }
            self.counts = counts
            self.total = counts.values.reduce(0, +)
        }

        /// log P(palabra | anterior).
        func logProb(_ word: String, prior: UInt8?) -> Double {
            let u = ContextModel.unigram(prior: prior)
            guard total > 0 else { return log(u) }
            let c = Double(counts[word.lowercased()] ?? 0)
            return log(ContextModel.lambda * c / Double(total) + (1 - ContextModel.lambda) * u)
        }

        /// Cuánto más probable es la palabra aquí que sola (0 si no lo es):
        /// sirve para desempatar trazos y correcciones.
        func boost(_ word: String, prior: UInt8?) -> Double {
            max(0, logProb(word, prior: prior) - log(ContextModel.unigram(prior: prior)))
        }

        /// Lo que más suele venir detrás, de más a menos.
        func likely(_ limit: Int) -> [String] {
            counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(limit).map { $0.key }
        }
    }

    /// Prior de una palabra en el vocabulario, si está entre las frecuentes.
    static func prior(of word: String, in lex: SwipeLexicon.Snapshot?) -> UInt8? {
        guard let lex, let keys = SwipeAlphabet.encode(word) else { return nil }
        return lex.prior(of: word.lowercased(), folded: SwipeLexicon.folded(keys))
    }

    /// La siguiente palabra más probable. `common` son las de reserva (las
    /// frecuentes de siempre) para cuando el contexto no sabe nada.
    static func nextWords(_ context: Context, lexicon: SwipeLexicon.Snapshot?, common: [String],
                          blocked: Set<String>, limit: Int = 3) -> [String] {
        var seen = Set<String>()
        var scored: [(word: String, score: Double)] = []
        for w in context.likely(24) + common.prefix(40) {
            let k = w.lowercased()
            guard !k.isEmpty, !blocked.contains(k), seen.insert(k).inserted else { continue }
            scored.append((w, context.logProb(k, prior: prior(of: k, in: lexicon))))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0.word }
    }

    // MARK: Completar la palabra en curso

    /// Dispersión del dedo alrededor del centro de la tecla, en teclas.
    static let sigma = 0.45
    /// Por proponer una palabra más larga que lo tecleado.
    static let completionPenalty = 1.5
    /// Más allá de este coste de toques (≈ dos teclas de error) no se mira.
    static let touchCutoff = -9.0

    /// Palabras que empiezan como lo tecleado, tolerando el dedo en la tecla
    /// vecina («hracias» ya propone «gracias»), ordenadas por probabilidad en
    /// el contexto. Cada letra cuenta como una gaussiana alrededor de su tecla
    /// (desplazada por el sesgo que aprendió `TouchModel`), con el punto
    /// donde cayó el dedo si se sabe y, si no, el centro de la tecla pulsada.
    static func completions(for typed: String, touches: [CGPoint],
                            keyCenters: [UInt8: CGPoint], keySize: CGSize,
                            context: Context, lexicon lex: SwipeLexicon.Snapshot,
                            limit: Int = 3) -> [String] {
        let lower = typed.lowercased()
        guard let keys = SwipeAlphabet.encode(lower), !keys.isEmpty, keys.count <= 20 else { return [] }
        let n = keys.count
        let geometry = SmartCorrector.Geometry(input: SmartCorrector.Input(word: typed, keyCenters: keyCenters,
                                                                           keySize: keySize))
        let w = Double(max(geometry.keySize.width, 1)), h = Double(max(geometry.keySize.height, 1))
        let useTouches = touches.count == n && !keyCenters.isEmpty

        // Coste de que la letra i tecleada fuera en realidad la tecla k.
        var table = [[Double]](repeating: [Double](repeating: -.infinity, count: SwipeAlphabet.count), count: n)
        for i in 0..<n {
            guard let from = useTouches ? touches[i] : geometry.centers[keys[i]] else { continue }
            for k in 0..<SwipeAlphabet.count {
                guard let c = geometry.centers[UInt8(k)] else { continue }
                let bias = TouchModel.bias(SwipeAlphabet.letters[k])
                let dx = (Double(from.x - c.x)) / w - bias.x
                let dy = (Double(from.y - c.y)) / h - bias.y
                table[i][k] = -(dx * dx + dy * dy) / (2 * sigma * sigma)
            }
        }

        // Una tilde puesta a mano se respeta: sólo palabras que la conservan.
        let accented = lower != SwipeLexicon.folded(keys)
        var best: [(word: String, score: Double)] = []
        for i in 0..<lex.count {
            let len = Int(lex.lens[i])
            guard len >= n else { continue }
            let s = Int(lex.starts[i])
            var cost = 0.0
            for j in 0..<n {
                cost += table[j][Int(lex.flat[s + j])]
                if cost < touchCutoff { break }
            }
            guard cost >= touchCutoff else { continue }
            let word = lex.words[i]
            if word == lower || (accented && !word.hasPrefix(lower)) { continue }
            let score = cost + context.logProb(word, prior: lex.priors[i]) - (len > n ? completionPenalty : 0)
            if best.count < limit * 2 || score > best[best.count - 1].score {
                best.append((word, score))
                best.sort { $0.score > $1.score }
                if best.count > limit * 2 { best.removeLast() }
            }
        }
        var seen = Set<String>()
        return best.filter { seen.insert($0.word).inserted }.prefix(limit).map { $0.word }
    }
}
