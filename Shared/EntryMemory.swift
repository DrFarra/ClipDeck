import Foundation

/// Correos y números que el usuario escribe a menudo, para proponerlos.
///
/// El vocabulario sólo aprende palabras de letras: un correo o un teléfono no
/// pasaban nunca de ahí y había que teclearlos enteros cada vez. Aquí se
/// guardan aparte, con las veces que se usaron (una por campo de texto, no por
/// pulsación), y se proponen en la barra:
///   · en un campo de correo o de teléfono, desde la primera letra;
///   · en texto normal, al escribir «@» o tres cifras seguidas.
///
/// Nunca entra lo de campos de contraseña, códigos de un solo uso o tarjetas,
/// ni un número que pase la prueba de Luhn (una tarjeta escrita en cualquier
/// campo). Todo se queda en el dispositivo.
enum EntryMemory {

    enum Kind: String, Codable { case email, number }

    struct Entry: Codable, Equatable {
        var text: String
        var kind: Kind
        var uses: Int
        var last: Date
    }

    static let storeKey = "kb.entries"
    static let maxEntries = 60
    /// En texto normal sólo se propone lo usado al menos estas veces.
    static let minUsesOutsideField = 2

    // MARK: Detección

    private static let emailPattern = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)*\\.[A-Za-z]{2,}")
    /// Un número de 7 a 15 cifras, con espacios, guiones o paréntesis entre medias.
    private static let numberPattern = try! NSRegularExpression(
        pattern: "(?<![\\w+@.])\\+?\\d[\\d \\-()]{5,}\\d(?![\\w@])")

    /// Correos y números de un texto, tal como están escritos.
    static func extract(_ text: String) -> [(text: String, kind: Kind)] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        var out: [(text: String, kind: Kind)] = []
        var taken: [NSRange] = []
        for m in emailPattern.matches(in: text, range: all) {
            out.append((ns.substring(with: m.range), .email))
            taken.append(m.range)
        }
        for m in numberPattern.matches(in: text, range: all)
        where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let raw = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            if isRememberableNumber(raw) { out.append((raw, .number)) }
        }
        return out
    }

    static func digits(_ s: String) -> String {
        (s.hasPrefix("+") ? "+" : "") + s.filter(\.isNumber)
    }

    /// De 7 a 15 cifras, no todas iguales y que no parezca una tarjeta.
    static func isRememberableNumber(_ s: String) -> Bool {
        let d = s.filter(\.isNumber)
        guard (7...15).contains(d.count), Set(d).count > 1 else { return false }
        return !(d.count >= 13 && passesLuhn(d))
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var n = c.wholeNumberValue else { return false }
            if i % 2 == 1 { n *= 2; if n > 9 { n -= 9 } }
            sum += n
        }
        return sum % 10 == 0
    }

    /// Cómo se compara una entrada: el correo sin mayúsculas, el número por sus cifras.
    static func key(_ text: String, _ kind: Kind) -> String {
        kind == .email ? text.lowercased() : digits(text)
    }

    // MARK: Lógica (pura, la cubren las pruebas)

    /// Suma un uso a cada entrada (o la crea) y poda las menos usadas.
    static func remember(_ found: [(text: String, kind: Kind)], into entries: inout [Entry], now: Date = Date()) {
        for f in found {
            let k = key(f.text, f.kind)
            if let i = entries.firstIndex(where: { key($0.text, $0.kind) == k }) {
                entries[i].uses += 1
                entries[i].last = now
                entries[i].text = f.text           // la forma escrita más reciente
            } else {
                entries.append(Entry(text: f.text, kind: f.kind, uses: 1, last: now))
            }
        }
        if entries.count > maxEntries {
            entries.sort { $0.uses == $1.uses ? $0.last > $1.last : $0.uses > $1.uses }
            entries.removeLast(entries.count - maxEntries)
        }
    }

    /// Lo que proponer para `token` (lo escrito desde el último espacio).
    /// `field`: el campo es de correo o de teléfono; nil si es texto normal.
    static func suggestions(for token: String, field: Kind?, in entries: [Entry], limit: Int = 3) -> [String] {
        let kind: Kind
        let inField: Bool
        if let field {
            kind = field; inField = true
        } else if token.contains("@") {
            kind = .email; inField = false
        } else if token.filter(\.isNumber).count >= 3, token.allSatisfy({ $0.isNumber || " -()+".contains($0) }) {
            kind = .number; inField = false
        } else {
            return []
        }
        let wanted = key(token, kind)
        return entries
            .filter { e in
                let k = key(e.text, e.kind)
                return e.kind == kind && k.hasPrefix(wanted) && k != wanted
                    && (inField || e.uses >= minUsesOutsideField)
            }
            .sorted { $0.uses == $1.uses ? $0.last > $1.last : $0.uses > $1.uses }
            .prefix(limit)
            .map(\.text)
    }

    // MARK: Almacenamiento (App Group)

    private static let lock = NSLock()

    static func all() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private static func load() -> [Entry] {
        guard let data = KbPrefs.store.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) { KbPrefs.store.set(data, forKey: storeKey) }
    }

    static func remember(_ found: [(text: String, kind: Kind)]) {
        guard !found.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var list = load()
        remember(found, into: &list)
        save(list)
    }

    @discardableResult
    static func forget(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        let before = list.count
        list.removeAll { $0.text == text || key($0.text, $0.kind) == key(text, $0.kind) }
        guard list.count != before else { return false }
        save(list)
        return true
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        KbPrefs.store.removeObject(forKey: storeKey)
    }
}
