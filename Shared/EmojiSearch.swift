import Foundation

/// Búsqueda de emojis por su nombre y sus palabras clave en español.
///
/// Los datos salen de CLDR en el español de España y el de Latinoamérica («tarta»
/// y «pastel», «coche» y «carro»), ya sin tildes ni mayúsculas; los genera
/// scripts/generate_emoji_catalog.py. La ñ no se pliega: es otra letra, y
/// «moño» (🎀) no es «mono» (🐒).
///
/// Un emoji sale cuando cada palabra escrita empieza alguna palabra de su nombre
/// o de sus palabras clave: «gat» → 🐈, «corazon roj» → ❤️. Las palabras vacías
/// («de», «con»…) no hace falta que coincidan, y un plural busca también el
/// singular («gatos» → 🐈). Primero van los que se llaman justo así, luego los
/// que empiezan por lo escrito y luego el resto según dónde coincida; a igualdad,
/// en el orden de los datos, que va de los más usados a los menos.
struct EmojiSearchIndex: Sendable {
    struct Entry: Sendable {
        let emoji: String
        /// El nombre oficial primero; detrás, el de otras variantes del español.
        let names: [String]
        let nameWords: [String]
        let keywords: [String]
    }

    let entries: [Entry]

    /// Las mismas que `STOPWORDS` en el generador.
    static let stopwords: Set<String> = [
        "a", "al", "con", "de", "del", "e", "el", "en", "la", "las", "lo", "los",
        "mi", "o", "para", "por", "que", "se", "sin", "su", "sus", "te", "tu",
        "u", "un", "una", "unas", "unos", "y"
    ]

    /// Una línea por emoji: «emoji ⇥ nombre|otro nombre ⇥ palabras clave».
    /// Lo de `excluded` (lo que este iPhone no sabe dibujar) no se encuentra.
    init(data: String, excluding excluded: Set<String> = []) {
        var list: [Entry] = []
        list.reserveCapacity(2048)
        for line in data.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let emoji = String(fields[0]).trimmingCharacters(in: .whitespaces)
            guard !emoji.isEmpty, !excluded.contains(emoji) else { continue }
            let names = fields[1].split(separator: "|").map(String.init)
            var nameWords: [String] = []
            for name in names {
                for word in name.split(separator: " ") where !nameWords.contains(where: { $0 == word }) {
                    nameWords.append(String(word))
                }
            }
            let keywords = fields.count > 2 ? fields[2].split(separator: " ").map(String.init) : []
            list.append(Entry(emoji: emoji, names: names, nameWords: nameWords, keywords: keywords))
        }
        entries = list
    }

    /// Las palabras de un texto tal como se comparan: sin tildes (salvo la ñ),
    /// en minúsculas y sin signos.
    static func tokens(_ text: String) -> [String] {
        let folded = text.lowercased()
            .split(separator: "ñ", omittingEmptySubsequences: false)
            .map { TextRules.fold(String($0)) }
            .joined(separator: "ñ")
        var words: [String] = []
        var current = ""
        for c in folded {
            if c.isLetter || c.isNumber || c == "#" || c == "*" {
                current.append(c)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    func search(_ query: String, limit: Int = 160) -> [String] {
        let all = Self.tokens(query)
        guard !all.isEmpty else { return [] }
        // Lo escrito tal cual y en singular: «gatos» encuentra primero a 🐈 «gato».
        let phrase = all.joined(separator: " ")
        let singular = all.map { Self.singular(of: $0) ?? $0 }.joined(separator: " ")
        let phrases = singular == phrase ? [phrase] : [phrase, singular]
        let significant = all.filter { !Self.stopwords.contains($0) }
        let query = Query(phrases: phrases, wordPrefixes: phrases.map { $0 + " " },
                          required: significant.isEmpty ? all : significant)
        var found: [(score: Int, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            if let score = Self.score(entry, query) {
                found.append((score, order))
            }
        }
        found.sort { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }
        return found.prefix(limit).map { entries[$0.order].emoji }
    }

    private struct Query {
        /// Lo escrito y su singular.
        let phrases: [String]
        /// Lo mismo seguido de un espacio: el nombre sigue con otra palabra.
        let wordPrefixes: [String]
        /// Las palabras que tienen que estar.
        let required: [String]
    }

    /// Menos es mejor; nil si alguna palabra no coincide.
    ///
    /// 0: se llama así («sol» → ☀️). 1: el nombre empieza con esas palabras
    /// («sol» → 🌞 «sol con cara»). 2 y 3: están enteras, en el nombre o entre
    /// las palabras clave («sol» → 😎 «gafas de sol»). 4: el nombre empieza por
    /// lo escrito a medias («gat» → 🐈 «gato»), que así no se adelanta a lo que
    /// coincide entero («te» → 🍵 antes que ☎️ «teléfono»). 5 y 6: alguna
    /// palabra sólo empieza igual.
    private static func score(_ entry: Entry, _ query: Query) -> Int? {
        var worst = 0
        for token in query.required {
            guard let quality = quality(of: token, in: entry) else { return nil }
            worst = max(worst, quality)
        }
        if entry.names.contains(where: { query.phrases.contains($0) }) { return 0 }
        if entry.names.contains(where: { name in query.wordPrefixes.contains { name.hasPrefix($0) } }) { return 1 }
        if worst < 2 { return 2 + worst }
        if entry.names.contains(where: { name in query.phrases.contains { name.hasPrefix($0) } }) { return 4 }
        return 3 + worst
    }

    /// 0: es una palabra del nombre; 1: una palabra clave; 2: empieza una
    /// palabra del nombre; 3: empieza una palabra clave.
    private static func quality(of token: String, in entry: Entry) -> Int? {
        if entry.nameWords.contains(token) { return 0 }
        if entry.keywords.contains(token) { return 1 }
        for form in forms(of: token) {
            if entry.nameWords.contains(where: { $0.hasPrefix(form) }) { return 2 }
        }
        for form in forms(of: token) {
            if entry.keywords.contains(where: { $0.hasPrefix(form) }) { return 3 }
        }
        return nil
    }

    /// La palabra y, si es un plural, sus posibles singulares: «flores» → «flor»,
    /// «gatos» → «gato», «llaves» → «llav» y «llave».
    private static func forms(of token: String) -> [String] {
        var result = [token]
        if token.count > 4, token.hasSuffix("es") { result.append(String(token.dropLast(2))) }
        if token.count > 3, token.hasSuffix("s") { result.append(String(token.dropLast())) }
        return result
    }

    /// El singular más corto de los posibles. Se compara como principio de
    /// nombre, así que «llav» (de «llaves») sirve para «llave».
    private static func singular(of token: String) -> String? {
        forms(of: token).dropFirst().first
    }
}
