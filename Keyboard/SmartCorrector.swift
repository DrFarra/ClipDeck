import UIKit

/// Autocorrector.
///
/// El anterior sólo le preguntaba al corrector del sistema por sus sugerencias
/// y se quedaba con la primera que tuviera un largo parecido. Eso ignora dos
/// cosas que sí sabemos:
///
///   1. Qué teclas están al lado de cuáles. Cambiar una "s" por una "d" es un
///      error normal; cambiarla por una "p" no lo es. Y si además guardamos
///      dónde cayó el dedo, sabemos si ese toque estuvo a medio camino entre
///      dos teclas o clavado en el centro.
///   2. Qué escribe el usuario. Sus palabras aprendidas y qué palabra suele
///      seguir a la anterior pesan en la decisión.
///
/// Además, como el vocabulario guarda las palabras con su tilde y las compara
/// sin ella, "cancion" encuentra "canción" con distancia cero: las tildes se
/// restauran solas.
enum SmartCorrector {

    struct Candidate {
        var word: String
        var score: Double
    }

    /// Devuelve la corrección propuesta, o nil si conviene no tocar nada.
    static func correction(for word: String,
                           touches: [CGPoint],
                           keyCenters: [UInt8: CGPoint],
                           keySize: CGSize,
                           previous: String) -> String? {

        let lower = word.lowercased()
        guard lower.count >= 3, lower.count <= 20,
              word != word.uppercased() || word.count < 2,
              lower.rangeOfCharacter(from: .decimalDigits) == nil,
              !WordLearner.isKnown(lower) else { return nil }
        guard let typed = SwipeAlphabet.encode(lower) else { return nil }

        // Si la palabra existe tal cual en algún idioma, no se toca.
        if isSpelledCorrectly(word) { return nil }

        let lex = SwipeLexicon.shared
        guard lex.isLoaded, lex.count > 0 else { return nil }

        var typedMask: UInt32 = 0
        for i in typed { typedMask |= (UInt32(1) << UInt32(i)) }

        let n = typed.count
        let usePoints = touches.count == n && keySize.width > 1 && !keyCenters.isEmpty
        let successors = Set(WordLearner.successors(of: previous).map { $0.lowercased() })

        var best = Candidate(word: "", score: .greatestFiniteMagnitude)
        var runnerUp = Double.greatestFiniteMagnitude

        let words = lex.words
        let flat = lex.flat
        let starts = lex.starts
        let lens = lex.lens
        let masks = lex.masks
        let priors = lex.priors

        var candidate = [UInt8]()
        candidate.reserveCapacity(24)

        for i in 0..<lex.count {
            let len = Int(lens[i])
            if abs(len - n) > 1 { continue }
            if (masks[i] ^ typedMask).nonzeroBitCount > 4 { continue }

            let s = Int(starts[i])
            candidate.removeAll(keepingCapacity: true)
            for k in 0..<len { candidate.append(flat[s + k]) }

            let d = distance(typed: typed, candidate: candidate,
                             touches: usePoints ? touches : [],
                             centers: keyCenters, keySize: keySize,
                             cutoff: 2.2)
            guard d < 2.2 else { continue }

            var score = d
            score -= Double(priors[i]) / 255.0 * 0.55
            if successors.contains(words[i]) { score -= 0.45 }
            if words[i] == lower { continue }

            if score < best.score {
                runnerUp = best.score
                best = Candidate(word: words[i], score: score)
            } else if score < runnerUp {
                runnerUp = score
            }
        }

        guard !best.word.isEmpty, best.score <= 1.15 else { return nil }
        // Si hay dos candidatos casi empatados, mejor no adivinar.
        guard runnerUp - best.score >= 0.12 || best.score <= 0.05 else { return nil }

        return matchCase(of: word, to: best.word)
    }

    // MARK: Distancia

    /// Distancia de edición con sustituciones ponderadas por la distancia real
    /// entre teclas (y por dónde cayó el dedo, si lo sabemos).
    private static func distance(typed: [UInt8], candidate: [UInt8],
                                 touches: [CGPoint], centers: [UInt8: CGPoint],
                                 keySize: CGSize, cutoff: Double) -> Double {
        let n = typed.count, m = candidate.count
        if n == 0 { return Double(m) }
        if m == 0 { return Double(n) }

        var prev2 = [Double](repeating: 0, count: m + 1)
        var prev = [Double](repeating: 0, count: m + 1)
        var cur = [Double](repeating: 0, count: m + 1)
        for j in 0...m { prev[j] = Double(j) }

        for i in 1...n {
            cur[0] = Double(i)
            var rowBest = cur[0]
            for j in 1...m {
                let a = typed[i - 1], b = candidate[j - 1]
                let sub = a == b ? 0 : substitutionCost(typedIndex: i - 1, typedKey: a, target: b,
                                                        touches: touches, centers: centers,
                                                        keySize: keySize)
                var value = min(prev[j] + 1.0,            // sobra una letra
                                cur[j - 1] + 1.0)         // falta una letra
                value = min(value, prev[j - 1] + sub)
                if i > 1, j > 1, typed[i - 1] == candidate[j - 2], typed[i - 2] == candidate[j - 1] {
                    value = min(value, prev2[j - 2] + 0.75)   // letras cambiadas de orden
                }
                cur[j] = value
                if value < rowBest { rowBest = value }
            }
            if rowBest > cutoff { return cutoff + 1 }      // corta pronto lo imposible
            // Rota los tres buffers en vez de reservar memoria en cada fila.
            let recycled = prev2
            prev2 = prev
            prev = cur
            cur = recycled
        }
        return prev[m]
    }

    private static func substitutionCost(typedIndex: Int, typedKey: UInt8, target: UInt8,
                                         touches: [CGPoint], centers: [UInt8: CGPoint],
                                         keySize: CGSize) -> Double {
        guard let targetCenter = centers[target] else { return 1.0 }
        let bias = TouchModel.bias(letter(target))
        let adjusted = CGPoint(x: targetCenter.x + CGFloat(bias.x) * keySize.width,
                               y: targetCenter.y + CGFloat(bias.y) * keySize.height)

        let from: CGPoint
        if typedIndex < touches.count {
            from = touches[typedIndex]                 // dónde cayó el dedo de verdad
        } else if let c = centers[typedKey] {
            from = c                                   // sin datos: centro a centro
        } else {
            return 1.0
        }

        let dx = (from.x - adjusted.x) / max(keySize.width, 1)
        let dy = (from.y - adjusted.y) / max(keySize.height, 1)
        let d = sqrt(Double(dx * dx + dy * dy))
        // Una tecla pegada cuesta poco; una lejana, lo mismo que borrar y poner.
        return min(1.0, max(0.30, d * 0.55))
    }

    private static func letter(_ index: UInt8) -> Character {
        let i = Int(index)
        guard i >= 0, i < SwipeAlphabet.letters.count else { return "a" }
        return SwipeAlphabet.letters[i]
    }

    // MARK: Utilidades

    private static func isSpelledCorrectly(_ word: String) -> Bool {
        let checker = KeyboardViewController.sharedChecker
        let range = NSRange(location: 0, length: word.utf16.count)
        for language in ["es_ES", "en_US"] {
            let m = checker.rangeOfMisspelledWord(in: word, range: range,
                                                  startingAt: 0, wrap: false, language: language)
            if m.location == NSNotFound { return true }
        }
        return false
    }

    private static func matchCase(of original: String, to replacement: String) -> String {
        guard let first = original.first else { return replacement }
        if first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
