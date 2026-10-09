import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Autocorrector.
///
/// Decide si una palabra recién escrita es una errata y por cuál cambiarla.
/// Usa lo que sabemos y el corrector del sistema no:
///
///   1. Qué teclas están al lado de cuáles y dónde cayó el dedo. Cambiar una
///      «s» por una «d» es un error normal; por una «p», no.
///   2. Cómo se equivoca la gente al escribir rápido: una letra pulsada dos
///      veces, dos teclas a la vez, una doble que se queda en una («ll»), la
///      «h» que no suena, b/v, s/z/c, la «ñ» que se escribe «n», dos letras
///      cambiadas de orden o el espacio que no entró («holaque»).
///   3. Qué palabras se usan más (lista de frecuencia) y cuáles escribe el
///      usuario, y qué suele seguir a la anterior.
///
/// Y, sobre todo, cuándo no tocar nada: palabras bien escritas, las que el
/// usuario ya usa o ya escribió en este texto, siglas, nombres a mitad de
/// frase y palabras de otro idioma salvo errata clarísima.
///
/// Vive en `Shared` para que las pruebas lo cubran: no depende del teclado,
/// el corrector ortográfico del sistema le llega como `spelling`.
enum SmartCorrector {

    /// Qué dice el diccionario del sistema de la palabra tal cual.
    enum Spelling {
        /// Existe en el idioma en que se está escribiendo.
        case valid
        /// Sólo existe en otro idioma activo («tine» es inglés, pero en un
        /// texto en español casi seguro es «tiene»).
        case otherLanguage
        /// Sólo existe con mayúscula: un nombre propio escrito en minúscula
        /// («carlos», «españa»). Se le pone la mayúscula.
        case properNoun
        /// No existe.
        case unknown
    }

    struct Input {
        var word: String
        /// Palabra anterior (para lo que suele seguirle).
        var previous: String = ""
        /// Dónde cayó el dedo en cada letra, si se sabe.
        var touches: [CGPoint] = []
        var keyCenters: [UInt8: CGPoint] = [:]
        var keySize: CGSize = .zero
        /// La palabra no empieza frase: ahí una mayúscula suele ser un nombre.
        var midSentence = false
        /// Palabras que ya están en el texto (en minúsculas): si el usuario
        /// las dejó así antes, son a propósito.
        var seenWords: Set<String> = []
    }

    /// Devuelve la corrección propuesta, o nil si conviene no tocar nada.
    static func correction(_ input: Input,
                           lexicon: SwipeLexicon.Snapshot?,
                           spelling: (String) -> Spelling,
                           isKnown: (String) -> Bool = WordLearner.isKnown,
                           successors: (String) -> [String] = WordLearner.successors) -> String? {
        var word = input.word

        // «HOla» → «Hola»: la mayúscula se soltó una letra tarde.
        var casingFix: String?
        let chars = Array(word)
        if chars.count >= 3, chars[0].isUppercase, chars[1].isUppercase,
           chars[2...].contains(where: { $0.isLowercase }),
           !chars[2...].contains(where: { $0.isUppercase }) {
            word = String(chars[0]) + String(chars[1...]).lowercased()
            casingFix = word
        }

        let lower = word.lowercased()
        guard lower.count >= 2, lower.count <= 24,
              lower.rangeOfCharacter(from: .decimalDigits) == nil,
              word != word.uppercased() else { return casingFix }    // siglas: «ONU», «OK»
        if isKnown(lower) || input.seenWords.contains(lower) || isChatWord(lower) { return casingFix }

        let spelled = spelling(word)
        if spelled == .valid { return casingFix }
        // Lo que queda si no hay mejor corrección.
        let fallback = spelled == .properNoun ? word.prefix(1).uppercased() + word.dropFirst() : casingFix
        guard lower.count >= 3, let lex = lexicon, lex.count > 0,
              let typed = SwipeAlphabet.encode(lower) else { return fallback }

        // Ya es una palabra frecuente tal cual (con su tilde): no es errata.
        if let hit = lex.lookup(folded: SwipeLexicon.folded(typed)), hit.word == lower {
            return casingFix
        }

        // Cuánto puede alejarse la corrección de lo tecleado. La frecuencia
        // sólo elige entre candidatas: no basta para cambiar una palabra que
        // el diccionario no conoce (un nombre, una marca, jerga).
        let capitalized = word.first?.isUppercase == true
        var limit = Tuning.maxDistance(letters: typed.count)
        if spelled == .otherLanguage { limit *= Tuning.otherLanguageFactor }
        if capitalized && input.midSentence { limit *= Tuning.nameFactor }   // casi seguro un nombre

        let geometry = Geometry(input: input)
        let successors = Set(successors(input.previous).map { $0.lowercased() })

        // Sólo existe con mayúscula: un nombre. Antes de ponérsela, una errata
        // mínima hacia una palabra común («senor» → «señor», «cafe» → «café»).
        if spelled == .properNoun { limit = min(limit, Tuning.properNounDistance) }
        if let fix = bestWord(typed: typed, lower: lower, lex: lex, geometry: geometry,
                              touches: input.touches, successors: successors, limit: limit) {
            return matchCase(of: word, to: fix)
        }
        if spelled == .properNoun { return fallback }
        if spelled == .unknown, !(capitalized && input.midSentence),
           let split = bestSplit(typed: typed, lex: lex, geometry: geometry, previous: input.previous) {
            return matchCase(of: word, to: split)
        }
        return fallback
    }

    // MARK: Una palabra

    private static func bestWord(typed: [UInt8], lower: String, lex: SwipeLexicon.Snapshot,
                                 geometry: Geometry, touches: [CGPoint],
                                 successors: Set<String>, limit: Double) -> String? {
        var typedMask: UInt32 = 0
        for i in typed { typedMask |= (UInt32(1) << UInt32(i)) }

        let n = typed.count
        // Con 6 letras o más caben dos de diferencia («hhoolaa» no, pero
        // «aplicaion» por «aplicación» sí).
        let maxLengthGap = n >= 6 ? 2 : 1
        let cost = Costs(typed: typed, geometry: geometry,
                         touches: touches.count == n ? touches : [])
        // Las tildes que el usuario puso a propósito («abló», «cómpo») se
        // respetan: entre «hablo» y «habló» gana la que las conserva.
        let typedAccents = lower.filter { SwipeAlphabet.index($0) != nil && !SwipeAlphabet.letters.contains($0) }

        var bestWord = ""
        var bestKeys: [UInt8] = []
        var bestDistance = Double.greatestFiniteMagnitude
        var bestScore = Double.greatestFiniteMagnitude
        var runnerUp = Double.greatestFiniteMagnitude

        let words = lex.words, flat = lex.flat, starts = lex.starts
        let lens = lex.lens, masks = lex.masks, priors = lex.priors

        var candidate = [UInt8]()
        candidate.reserveCapacity(24)

        for i in 0..<lex.count {
            let len = Int(lens[i])
            if abs(len - n) > maxLengthGap { continue }
            if (masks[i] ^ typedMask).nonzeroBitCount > 4 { continue }
            if words[i] == lower { continue }

            let s = Int(starts[i])
            candidate.removeAll(keepingCapacity: true)
            for k in 0..<len { candidate.append(flat[s + k]) }

            let d = cost.distance(to: candidate, cutoff: 2.2)
            guard d < 2.2 else { continue }

            var score = d - Double(priors[i]) / 255.0 * Tuning.priorWeight
            if successors.contains(words[i]) { score -= Tuning.successorBonus }
            for accent in typedAccents where !words[i].contains(accent) { score += Tuning.lostAccent }

            // Dos palabras que se teclean igual («esta», «está») no son un
            // empate: gana la más usada, que ya lleva su ventaja en `score`.
            if score < bestScore {
                if candidate != bestKeys { runnerUp = bestScore }
                bestWord = words[i]
                bestKeys = candidate
                bestDistance = d
                bestScore = score
            } else if score < runnerUp, candidate != bestKeys {
                runnerUp = score
            }
        }

        guard !bestWord.isEmpty, bestDistance <= limit else { return nil }
        // Dos candidatas casi empatadas: mejor no adivinar.
        guard runnerUp - bestScore >= Tuning.tieMargin || bestDistance == 0 else { return nil }
        return bestWord
    }

    // MARK: Ajustes

    /// Medidos con `Tests` y con un banco de unas 3000 erratas generadas a
    /// partir de las palabras más usadas (ver `SmartCorrectorTests`).
    enum Tuning {
        /// Distancia máxima según las letras tecleadas: en una palabra corta
        /// un solo cambio ya la convierte en otra.
        static func maxDistance(letters n: Int) -> Double {
            switch n {
            case ...3: return 0.5
            case 4: return 0.75
            case 5...6: return 0.9
            default: return 1.1
            }
        }
        static let otherLanguageFactor = 0.6
        /// Un nombre en minúscula sólo se cambia por otra palabra si la errata
        /// es de tilde, de «ñ» o de tecla repetida.
        static let properNounDistance = 0.36
        static let nameFactor = 0.45
        static let priorWeight = 0.55
        static let successorBonus = 0.45
        static let tieMargin = 0.08
        /// Por cada tilde tecleada que la candidata no tiene.
        static let lostAccent = 0.25
    }

    // MARK: Jerga de chat

    /// Lo que se escribe así a propósito y ningún diccionario trae.
    private static let chatWords: Set<String> = [
        "ok", "okey", "oki", "porfa", "porfis", "plis", "pls", "finde", "tqm", "tkm", "ily",
        "wsp", "wpp", "bro", "pq", "xq", "pk", "tmb", "tb", "tmbn", "msj", "bn", "dale",
        "osea", "nose", "holis", "wey", "güey", "che", "ntp", "npn", "vdd", "xfa", "grax",
        "xd", "lol", "omg", "btw", "jsjs", "aja", "ajá", "ahre", "nah", "mmm", "uff", "ufff",
    ]

    /// Risas («jajaja», «jejeje», «jsjsjs», «hahaha») y la jerga de arriba.
    static func isChatWord(_ lower: String) -> Bool {
        if chatWords.contains(lower) { return true }
        let c = Array(lower)
        guard c.count >= 4 else { return false }
        // Sílabas que se repiten: «ja», «je», «ji», «jo», «js», «ha», «he».
        let a = c[0], b = c[1]
        guard "jh".contains(a), "aeiosu".contains(b) else { return false }
        for (i, ch) in c.enumerated() where ch != (i % 2 == 0 ? a : b) { return false }
        return true
    }

    // MARK: Palabras pegadas

    /// Palabras de una letra que pueden quedar a un lado del espacio perdido.
    private static let oneLetterWords: Set<UInt8> = Set("ayo".compactMap { SwipeAlphabet.index($0) })
    /// Teclas justo encima de la barra espaciadora: pulsadas en lugar del espacio.
    private static let spaceNeighbours: Set<UInt8> = Set("cvbnm".compactMap { SwipeAlphabet.index($0) })
    /// Las dos mitades tienen que ser palabras muy usadas (o del usuario).
    private static let splitPrior: UInt8 = 140

    /// «holaque» → «hola que», «holabque» → «hola que» (la «b» en lugar del
    /// espacio). Sólo con palabras frecuentes a los dos lados.
    private static func bestSplit(typed: [UInt8], lex: SwipeLexicon.Snapshot,
                                  geometry: Geometry, previous: String) -> String? {
        let n = typed.count
        guard n >= 4 else { return nil }

        func part(_ keys: ArraySlice<UInt8>) -> (word: String, prior: UInt8)? {
            if keys.count == 1, let k = keys.first, oneLetterWords.contains(k) {
                return (String(SwipeAlphabet.letters[Int(k)]), 230)
            }
            guard keys.count >= 2, let hit = lex.lookup(folded: SwipeLexicon.folded(Array(keys))),
                  hit.prior >= splitPrior else { return nil }
            return hit
        }

        var best: (text: String, score: Double)?
        func consider(_ left: ArraySlice<UInt8>, _ right: ArraySlice<UInt8>, base: Double) {
            guard let l = part(left), let r = part(right) else { return }
            let score = base - (Double(l.prior) + Double(r.prior)) / 510.0 * 0.55
            if best == nil || score < best!.score { best = (l.word + " " + r.word, score) }
        }
        for i in 1..<n {
            consider(typed[..<i], typed[i...], base: 0.45)
            // La letra en i se pulsó en vez del espacio.
            if i < n - 1, spaceNeighbours.contains(typed[i]) {
                consider(typed[..<i], typed[(i + 1)...], base: 0.55)
            }
        }
        return best?.text
    }

    // MARK: Costes de edición

    /// Posición de las teclas: la real si se conoce, si no un QWERTY español
    /// estándar (en unidades de tecla).
    struct Geometry {
        let centers: [UInt8: CGPoint]
        let keySize: CGSize

        init(input: Input) {
            if input.keyCenters.isEmpty || input.keySize.width <= 1 {
                centers = Geometry.qwerty
                keySize = CGSize(width: 1, height: 1)
            } else {
                centers = input.keyCenters
                keySize = input.keySize
            }
        }

        static let qwerty: [UInt8: CGPoint] = {
            var c: [UInt8: CGPoint] = [:]
            let rows: [(String, Double)] = [("qwertyuiop", 0.5), ("asdfghjklñ", 0.5), ("zxcvbnm", 2.0)]
            for (r, (letters, x0)) in rows.enumerated() {
                for (i, ch) in letters.enumerated() {
                    if let k = SwipeAlphabet.index(ch) {
                        c[k] = CGPoint(x: x0 + Double(i), y: 0.5 + Double(r))
                    }
                }
            }
            return c
        }()

        /// Distancia entre dos teclas, en teclas.
        func keyDistance(_ a: UInt8, _ b: UInt8) -> Double {
            guard let p = centers[a], let q = centers[b] else { return 10 }
            let dx = Double(p.x - q.x) / Double(max(keySize.width, 1))
            let dy = Double(p.y - q.y) / Double(max(keySize.height, 1))
            return (dx * dx + dy * dy).squareRoot()
        }

        func adjacent(_ a: UInt8, _ b: UInt8) -> Bool { keyDistance(a, b) <= 1.25 }
    }

    /// Confusiones de ortografía, no de dedo: cuestan poco aunque las teclas
    /// estén lejos.
    private static let spellingSwaps: [UInt16: Double] = {
        var t: [UInt16: Double] = [:]
        func add(_ a: Character, _ b: Character, _ cost: Double) {
            guard let x = SwipeAlphabet.index(a), let y = SwipeAlphabet.index(b) else { return }
            t[UInt16(x) << 8 | UInt16(y)] = cost
            t[UInt16(y) << 8 | UInt16(x)] = cost
        }
        add("n", "ñ", 0.2)      // «nino» → «niño»
        add("b", "v", 0.5)      // «bamos» → «vamos»
        add("s", "z", 0.6)      // seseo: «sapato» → «zapato»
        add("c", "z", 0.6)
        add("c", "s", 0.7)
        add("g", "j", 0.7)      // «coje» → «coge»
        add("y", "i", 0.7)
        return t
    }()

    private static let hKey = SwipeAlphabet.index("h")!

    /// Costes de editar lo tecleado hacia una candidata.
    private struct Costs {
        let typed: [UInt8]
        let geometry: Geometry
        let touches: [CGPoint]
        /// Coste de que la letra i sobre (precalculado).
        let extra: [Double]

        init(typed: [UInt8], geometry: Geometry, touches: [CGPoint]) {
            self.typed = typed
            self.geometry = geometry
            self.touches = touches
            var extra = [Double](repeating: 1.0, count: typed.count)
            for i in typed.indices {
                if i > 0, typed[i] == typed[i - 1] {
                    extra[i] = 0.35                     // la misma tecla dos veces
                } else if (i > 0 && geometry.adjacent(typed[i], typed[i - 1]))
                            || (i + 1 < typed.count && geometry.adjacent(typed[i], typed[i + 1])) {
                    extra[i] = 0.65                     // dos teclas vecinas a la vez
                }
            }
            self.extra = extra
        }

        /// Coste de que falte la letra j de la candidata.
        func missing(_ candidate: [UInt8], _ j: Int) -> Double {
            if j > 0, candidate[j] == candidate[j - 1] { return 0.5 }   // «ll», «rr», «cc»
            if candidate[j] == SmartCorrector.hKey { return 0.55 }     // la «h» no suena
            return 0.85     // al escribir rápido se come una letra más que cambiarla
        }

        func substitution(_ i: Int, _ target: UInt8) -> Double {
            let typedKey = typed[i]
            let swap = SmartCorrector.spellingSwaps[UInt16(typedKey) << 8 | UInt16(target)] ?? 1.0
            guard let targetCenter = geometry.centers[target] else { return swap }
            let bias = TouchModel.bias(SwipeAlphabet.letters[Int(target)])
            let size = geometry.keySize
            let adjusted = CGPoint(x: targetCenter.x + CGFloat(bias.x) * size.width,
                                   y: targetCenter.y + CGFloat(bias.y) * size.height)
            let from: CGPoint
            if i < touches.count {
                from = touches[i]                       // dónde cayó el dedo de verdad
            } else if let c = geometry.centers[typedKey] {
                from = c                                // sin datos: centro a centro
            } else {
                return swap
            }
            let dx = Double(from.x - adjusted.x) / Double(max(size.width, 1))
            let dy = Double(from.y - adjusted.y) / Double(max(size.height, 1))
            let d = (dx * dx + dy * dy).squareRoot()
            // Una tecla pegada cuesta poco; una lejana, lo mismo que borrar y poner.
            return min(swap, min(1.0, max(0.30, d * 0.55)))
        }

        /// Distancia de edición ponderada. Corta en cuanto pasa de `cutoff`.
        func distance(to candidate: [UInt8], cutoff: Double) -> Double {
            let n = typed.count, m = candidate.count
            if n == 0 { return Double(m) }
            if m == 0 { return Double(n) }

            var prev2 = [Double](repeating: 0, count: m + 1)
            var prev = [Double](repeating: 0, count: m + 1)
            var cur = [Double](repeating: 0, count: m + 1)
            for j in 1...m { prev[j] = prev[j - 1] + missing(candidate, j - 1) }

            for i in 1...n {
                cur[0] = prev[0] + extra[i - 1]
                var rowBest = cur[0]
                for j in 1...m {
                    let a = typed[i - 1], b = candidate[j - 1]
                    var value = min(prev[j] + extra[i - 1],                     // sobra una letra
                                    cur[j - 1] + missing(candidate, j - 1))     // falta una letra
                    value = min(value, prev[j - 1] + (a == b ? 0 : substitution(i - 1, b)))
                    if i > 1, j > 1, a == candidate[j - 2], typed[i - 2] == b {
                        value = min(value, prev2[j - 2] + 0.6)                  // dos letras cambiadas
                    }
                    cur[j] = value
                    if value < rowBest { rowBest = value }
                }
                if rowBest > cutoff { return cutoff + 1 }    // corta pronto lo imposible
                // Rota los tres buffers en vez de reservar memoria en cada fila.
                let recycled = prev2
                prev2 = prev
                prev = cur
                cur = recycled
            }
            return prev[m]
        }
    }

    // MARK: Utilidades

    private static func matchCase(of original: String, to replacement: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}
