import Foundation

/// Clasificación heurística del contenido copiado.
enum ContentClassifier {

    static func classify(text: String) -> ClipContentType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plainText }

        if colorHex(from: trimmed) != nil { return .color }

        // URL exacta (todo el texto es una URL)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           !trimmed.contains(" ") {
            return .link
        }

        // Detectores del sistema sobre el texto completo
        if let detector = try? NSDataDetector(types:
            NSTextCheckingResult.CheckingType.link.rawValue |
            NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            let full = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = detector.matches(in: trimmed, options: [], range: full)
            if let m = matches.first, m.range == full {
                if m.resultType == .phoneNumber { return .phoneNumber }
                if let url = m.url {
                    if url.scheme == "mailto" { return .email }
                    return .link
                }
            }
        }

        if looksLikeCode(trimmed) { return .code }
        return .plainText
    }

    // MARK: Color

    /// Devuelve un hex normalizado "#RRGGBB" si el texto es un color.
    static func colorHex(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // #RGB o #RRGGBB
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst())
            let valid = hex.allSatisfy { $0.isHexDigit }
            if valid && hex.count == 6 { return "#" + hex.uppercased() }
            if valid && hex.count == 3 {
                let expanded = hex.map { "\($0)\($0)" }.joined()
                return "#" + expanded.uppercased()
            }
            return nil
        }

        // rgb(r, g, b)
        let lower = t.lowercased()
        if lower.hasPrefix("rgb(") && lower.hasSuffix(")") {
            let inner = lower.dropFirst(4).dropLast()
            let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) {
                return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
            }
        }
        return nil
    }

    // MARK: Código

    static func looksLikeCode(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        var score = 0
        if text.contains("{") && text.contains("}") { score += 2 }
        if text.contains(";") { score += 1 }
        if text.contains("</") || text.contains("/>") { score += 2 }
        let keywords = ["func ", "let ", "var ", "import ", "class ", "def ", "return ",
                        "const ", "function ", "public ", "private ", "#include", "SELECT ", "print("]
        for k in keywords where text.contains(k) { score += 1 }
        // Sangría consistente
        let indented = text.split(separator: "\n").filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }
        if indented.count >= 2 { score += 1 }
        return score >= 3
    }

    static func detectCodeLanguage(_ text: String) -> String? {
        let checks: [(String, [String])] = [
            ("Swift",      ["func ", "let ", "var ", "guard ", "import Swift", "@State"]),
            ("Python",     ["def ", "import ", "self.", "print(", "elif "]),
            ("JavaScript", ["const ", "=> ", "function ", "console.log", "let "]),
            ("HTML",       ["<div", "<html", "</p>", "<span"]),
            ("SQL",        ["SELECT ", "FROM ", "WHERE ", "INSERT INTO"]),
            ("JSON",       ["{\"", "\": \"", "\":["]),
            ("Shell",      ["#!/bin", "echo ", "grep ", "sudo "])
        ]
        var best: (String, Int) = ("", 0)
        for (lang, keys) in checks {
            let hits = keys.filter { text.contains($0) }.count
            if hits > best.1 { best = (lang, hits) }
        }
        return best.1 >= 2 ? best.0 : nil
    }

    // MARK: Contenido sensible

    /// Heurística conservadora: solo señales fuertes.
    static func looksSensitive(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let strongMarkers = ["-----BEGIN ", "PRIVATE KEY", "sk-", "ghp_", "xoxb-", "AKIA",
                             "api_key", "apikey", "secret_key", "Bearer "]
        for marker in strongMarkers where t.contains(marker) { return true }

        // Token único de alta entropía: sin espacios, largo, mezcla de clases
        if !t.contains(" "), (20...128).contains(t.count) {
            let hasUpper = t.rangeOfCharacter(from: .uppercaseLetters) != nil
            let hasLower = t.rangeOfCharacter(from: .lowercaseLetters) != nil
            let hasDigit = t.rangeOfCharacter(from: .decimalDigits) != nil
            let hasSymbol = t.rangeOfCharacter(from: CharacterSet(charactersIn: "-_./+=")) != nil
            if hasUpper && hasLower && hasDigit && hasSymbol { return true }
        }
        return false
    }
}
