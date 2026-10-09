import Foundation

/// Reglas de texto del teclado que no dependen de la interfaz: qué es una
/// palabra, cuándo empieza una frase, qué va detrás de una palabra corregida.
///
/// Viven en `Shared` para que las pruebas las cubran (el target de pruebas
/// compila esta carpeta, no la del teclado).
enum TextRules {

    static let wordSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,;:!?¿¡\"'()[]{}…«»“”‘’"))
    static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "\n", "\r", "\r\n"]
    static let openingPunctuation: Set<Character> = ["¿", "¡", "(", "[", "{", "«", "\"", "'", "“", "‘"]
    static let closingQuotes: Set<Character> = ["\"", "'", ")", "]", "}", "»", "”", "’"]

    static func isSeparator(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { wordSeparators.contains($0) }
    }

    /// La palabra que se está escribiendo (lo que hay desde el último separador).
    static func wordBefore(_ text: String) -> String {
        if let r = text.rangeOfCharacter(from: wordSeparators, options: .backwards) {
            return String(text[r.upperBound...])
        }
        return text
    }

    /// El resto de la palabra detrás del cursor (vacío si no está dentro de una).
    static func wordAfter(_ text: String) -> String {
        String(text.prefix { $0.isLetter || $0.isNumber })
    }

    /// Última palabra completa antes del cursor (para predecir la siguiente),
    /// sin cruzar el final de una frase.
    static func lastCompleteWord(in before: String) -> String {
        var text = Substring(before)
        while let c = text.last, isSeparator(c) {
            if sentenceEnders.contains(c) { return "" }
            text = text.dropLast()
        }
        return wordBefore(String(text))
    }

    /// La palabra anterior a la que se está escribiendo.
    static func previousWord(in before: String) -> String {
        let current = wordBefore(before)
        return lastCompleteWord(in: String(before.dropLast(current.count)))
    }

    /// Sólo letras: ni correos, ni números, ni «@usuario», ni «c/»…
    static func isPlainWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter }
    }

    static func startsWord(_ before: String) -> Bool {
        var text = Substring(before)
        while let last = text.last, openingPunctuation.contains(last) { text = text.dropLast() }
        guard let last = text.last else { return true }
        return last.isWhitespace
    }

    /// ¿Empieza una frase en el cursor? Hace falta un espacio (o un salto de
    /// línea) tras el punto: en «www.» o en «juan.» no toca mayúscula, y antes
    /// salía «www.Google.Com». Los signos de apertura no cuentan: «¿Qué» va
    /// en mayúscula igual que «Qué».
    static func startsSentence(_ before: String) -> Bool {
        var text = Substring(before)
        while let last = text.last, openingPunctuation.contains(last) { text = text.dropLast() }
        guard let last = text.last else { return true }
        if last.isNewline { return true }
        guard last.isWhitespace else { return false }
        while let l = text.last, l.isWhitespace, !l.isNewline { text = text.dropLast() }
        guard var end = text.last else { return true }
        if end.isNewline { return true }
        // Comillas o paréntesis de cierre tras el punto: «dijo "hola." Y…»
        while closingQuotes.contains(end) {
            text = text.dropLast()
            guard let l = text.last else { return false }
            end = l
        }
        return ".!?…".contains(end)
    }

    /// Caracteres que ocupa la última palabra (con los espacios que la siguen).
    static func lastWordLength(in before: String) -> Int {
        var chars = Array(before)
        var count = 0
        while let last = chars.last, last == " " { chars.removeLast(); count += 1 }
        while let last = chars.last, last != " ", !last.isNewline { chars.removeLast(); count += 1 }
        // Justo detrás de un salto de línea: se borra el salto.
        return count == 0 && !chars.isEmpty ? 1 : count
    }

    /// Lo que el usuario escribió detrás de `original` (espacio, «. », «?»…)
    /// si el texto sigue siendo «…original + separadores». nil si ya empezó
    /// otra palabra, movió el cursor o `original` era parte de otra palabra:
    /// entonces una corrección tardía no debe tocar nada.
    static func trailingSeparators(after original: String, in before: String) -> String? {
        let tail = String(before.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
        guard !tail.isEmpty, tail.count <= 3 else { return nil }
        let head = before.dropLast(tail.count)
        guard head.hasSuffix(original) else { return nil }
        if let c = head.dropLast(original.count).last, c.isLetter || c.isNumber { return nil }
        return tail
    }

    /// Para buscar sin distinguir tildes ni mayúsculas.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
