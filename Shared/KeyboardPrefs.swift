import Foundation

/// Preferencias del teclado, compartidas entre la app y la extensión
/// a través del App Group (el teclado las lee con acceso completo).
enum KbPrefs {
    static var store: UserDefaults { AppGroup.sharedDefaults }

    // Claves
    static let height          = "kb.height"            // 280...380
    static let keyHeight       = "kb.keyHeight"         // 36...48
    static let fontSize        = "kb.fontSize"          // 18...26
    static let numberRow       = "kb.numberRow"
    static let keyPopup        = "kb.keyPopup"
    static let prediction      = "kb.prediction"
    static let autocorrect     = "kb.autocorrect"
    static let learnWords      = "kb.learnWords"
    static let doubleSpace     = "kb.doubleSpacePeriod"
    static let autoCapital     = "kb.autoCapital"
    static let longPressAccents = "kb.longPressAccents"
    static let spaceTrackpad   = "kb.spaceTrackpad"
    static let sound           = "kb.sound"
    static let haptics         = "kb.haptics"
    static let punctLeft       = "kb.punctLeft"
    static let punctRight      = "kb.punctRight"

    static func double(_ key: String, default def: Double) -> Double {
        store.object(forKey: key) as? Double ?? def
    }
    static func bool(_ key: String, default def: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? def
    }

    /// Configuración resuelta con valores por defecto.
    struct Config {
        var height: Double
        var keyHeight: Double
        var fontSize: Double
        var numberRow: Bool
        var keyPopup: Bool
        var prediction: Bool
        var autocorrect: Bool
        var learnWords: Bool
        var doubleSpace: Bool
        var autoCapital: Bool
        var accents: Bool
        var trackpad: Bool
        var sound: Bool
        var haptics: Bool
        var punctLeft: String
        var punctRight: String

        static func load() -> Config {
            Config(height: KbPrefs.double(KbPrefs.height, default: 330),
                   keyHeight: KbPrefs.double(KbPrefs.keyHeight, default: 41),
                   fontSize: KbPrefs.double(KbPrefs.fontSize, default: 22),
                   numberRow: KbPrefs.bool(KbPrefs.numberRow, default: true),
                   keyPopup: KbPrefs.bool(KbPrefs.keyPopup, default: true),
                   prediction: KbPrefs.bool(KbPrefs.prediction, default: true),
                   autocorrect: KbPrefs.bool(KbPrefs.autocorrect, default: true),
                   learnWords: KbPrefs.bool(KbPrefs.learnWords, default: true),
                   doubleSpace: KbPrefs.bool(KbPrefs.doubleSpace, default: true),
                   autoCapital: KbPrefs.bool(KbPrefs.autoCapital, default: true),
                   accents: KbPrefs.bool(KbPrefs.longPressAccents, default: true),
                   trackpad: KbPrefs.bool(KbPrefs.spaceTrackpad, default: true),
                   sound: KbPrefs.bool(KbPrefs.sound, default: false),
                   haptics: KbPrefs.bool(KbPrefs.haptics, default: true),
                   punctLeft: KbPrefs.store.string(forKey: KbPrefs.punctLeft) ?? ",",
                   punctRight: KbPrefs.store.string(forKey: KbPrefs.punctRight) ?? ".")
        }
    }
}

// MARK: - Aprendizaje local de palabras (frecuencias y bigramas)

enum WordLearner {
    static let wordsKey = "kb.learnedWords"     // [palabra: frecuencia]
    static let bigramsKey = "kb.learnedBigrams" // ["prev next": frecuencia]

    static func learnedWords() -> [String: Int] {
        KbPrefs.store.dictionary(forKey: wordsKey) as? [String: Int] ?? [:]
    }

    static func isKnown(_ word: String) -> Bool {
        learnedWords()[word.lowercased()] != nil
    }

    static func learn(_ word: String) {
        let clean = word.lowercased()
        guard clean.count >= 2, clean.count <= 24,
              clean.rangeOfCharacter(from: .letters) != nil,
              clean.rangeOfCharacter(from: .decimalDigits) == nil else { return }
        var dict = learnedWords()
        dict[clean, default: 0] += 1
        if dict.count > 600 {
            // Poda: elimina las de menor frecuencia
            let sorted = dict.sorted { $0.value > $1.value }.prefix(500)
            dict = Dictionary(uniqueKeysWithValues: Array(sorted))
        }
        KbPrefs.store.set(dict, forKey: wordsKey)
    }

    static func learnBigram(previous: String, next: String) {
        let key = previous.lowercased() + " " + next.lowercased()
        guard key.count <= 40 else { return }
        var dict = KbPrefs.store.dictionary(forKey: bigramsKey) as? [String: Int] ?? [:]
        dict[key, default: 0] += 1
        if dict.count > 2000 {
            let sorted = dict.sorted { $0.value > $1.value }.prefix(1600)
            dict = Dictionary(uniqueKeysWithValues: Array(sorted))
        }
        KbPrefs.store.set(dict, forKey: bigramsKey)
    }

    /// Palabras que suelen seguir a `word` según lo que ha escrito el usuario.
    static func successors(of word: String) -> [String] {
        let prefix = word.lowercased() + " "
        let dict = KbPrefs.store.dictionary(forKey: bigramsKey) as? [String: Int] ?? [:]
        return dict
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { String($0.key.dropFirst(prefix.count)) }
    }

    /// Coincidencias del vocabulario aprendido para un prefijo.
    static func matches(prefix: String, limit: Int) -> [String] {
        let lower = prefix.lowercased()
        return learnedWords()
            .filter { $0.key.hasPrefix(lower) && $0.key != lower }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    static func clear() {
        KbPrefs.store.removeObject(forKey: wordsKey)
        KbPrefs.store.removeObject(forKey: bigramsKey)
    }

    static var learnedCount: Int { learnedWords().count }
}

// MARK: - Datos de escritura

enum KbData {
    /// Palabras muy frecuentes (español e inglés) para sugerencias de palabra siguiente.
    static let commonWords: [String] = [
        "de","que","no","la","el","en","y","a","los","se","del","las","un","por",
        "con","para","es","una","su","al","lo","como","más","pero","sus","le","ya",
        "o","este","sí","porque","esta","entre","cuando","muy","sin","sobre","también",
        "me","hasta","hay","donde","desde","todo","nos","todos","uno","les","ni","ese",
        "eso","ellos","esto","antes","algunos","qué","unos","yo","otro","otra","él",
        "tanto","esa","estos","mucho","nada","muchos","cual","poco","ella","estar",
        "estas","algo","nosotros","mi","mis","tú","te","ti","tu","tus","sí","bien",
        "gracias","hola","bueno","vamos","ahora","después","hoy","mañana","aquí",
        "the","to","and","of","in","is","it","you","that","was","for","on","are",
        "with","they","be","at","this","have","from","not","but","what","can","out",
        "we","up","so","if","about","who","get","which","go","me","when","make",
        "like","time","just","him","know","take","people","into","year","your","good",
        "some","could","them","see","other","than","then","now","only","its","over","also"
    ]

    /// Variantes por pulsación larga (acentos y símbolos alternativos).
    static let keyVariants: [String: [String]] = [
        "a": ["á","à","â","ä","ã"],
        "e": ["é","è","ê","ë"],
        "i": ["í","ì","î","ï"],
        "o": ["ó","ò","ô","ö","õ"],
        "u": ["ú","ù","ü","û"],
        "n": ["ñ"],
        "c": ["ç"],
        "y": ["ý"],
        "?": ["¿"],
        "!": ["¡"],
        "$": ["€","£","¥"],
        "-": ["–","—","•"],
        "\"": ["«","»","„"],
        "'": ["‘","’","`"],
        ".": ["…"]
    ]
}
