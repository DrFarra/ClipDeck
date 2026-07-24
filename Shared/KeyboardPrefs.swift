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
    static let hapticsLongPress = "kb.hapticsLongPress"
    static let swipe           = "kb.swipeTyping"
    static let trackpadStepY   = "kb.trackpadLineStep"     // pt por línea
    static let trackpadChars   = "kb.trackpadLineChars"    // ancho de línea estimado
    static let punctLeft       = "kb.punctLeft"
    static let punctRight      = "kb.punctRight"

    static func double(_ key: String, default def: Double) -> Double {
        store.object(forKey: key) as? Double ?? def
    }
    static func bool(_ key: String, default def: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? def
    }

    /// Configuración resuelta con valores por defecto.
    struct Config: Equatable {
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
        var hapticsLongPress: Bool
        var swipe: Bool
        var trackpadStepY: Double
        var trackpadChars: Double
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
                   hapticsLongPress: KbPrefs.bool(KbPrefs.hapticsLongPress, default: true),
                   swipe: KbPrefs.bool(KbPrefs.swipe, default: true),
                   trackpadStepY: KbPrefs.double(KbPrefs.trackpadStepY, default: 22),
                   trackpadChars: KbPrefs.double(KbPrefs.trackpadChars, default: 38),
                   punctLeft: KbPrefs.store.string(forKey: KbPrefs.punctLeft) ?? ",",
                   punctRight: KbPrefs.store.string(forKey: KbPrefs.punctRight) ?? ".")
        }
    }
}

// MARK: - Aprendizaje local de palabras (frecuencias y bigramas)

enum WordLearner {
    static let wordsKey = "kb.learnedWords"     // [palabra: frecuencia]
    static let bigramsKey = "kb.learnedBigrams" // ["prev next": frecuencia]
    static let blockedKey = "kb.blockedWords"   // palabras que el usuario no quiere ver

    // MARK: Caché en memoria
    //
    // Antes cada palabra aprendida releía y reescribía el diccionario completo
    // en UserDefaults (hasta 2600 entradas serializadas a plist) en pleno hilo
    // principal, en cada espacio. Ahora se mantiene en memoria y se persiste
    // de forma diferida en segundo plano.

    private static let lock = NSLock()
    private static var wordsCache: [String: Int]?
    private static var bigramsCache: [String: Int]?
    private static var blockedCache: Set<String>?
    private static var wordsDirty = false
    private static var bigramsDirty = false
    private static var flushScheduled = false

    private static func wordsDict() -> [String: Int] {
        if let c = wordsCache { return c }
        let d = KbPrefs.store.dictionary(forKey: wordsKey) as? [String: Int] ?? [:]
        wordsCache = d
        return d
    }

    private static func bigramsDict() -> [String: Int] {
        if let c = bigramsCache { return c }
        let d = KbPrefs.store.dictionary(forKey: bigramsKey) as? [String: Int] ?? [:]
        bigramsCache = d
        return d
    }

    /// Programa una escritura a disco fuera del hilo principal.
    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            flush()
        }
    }

    /// Persiste los cambios pendientes. Seguro de llamar en cualquier momento.
    static func flush() {
        lock.lock()
        let words = wordsDirty ? wordsCache : nil
        let bigrams = bigramsDirty ? bigramsCache : nil
        wordsDirty = false
        bigramsDirty = false
        flushScheduled = false
        lock.unlock()

        if let words { KbPrefs.store.set(words, forKey: wordsKey) }
        if let bigrams { KbPrefs.store.set(bigrams, forKey: bigramsKey) }
    }

    /// Descarta la caché para releer de disco (tras editar desde la app).
    static func invalidateCache() {
        lock.lock()
        wordsCache = nil
        bigramsCache = nil
        blockedCache = nil
        lock.unlock()
    }

    static func blockedWords() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = blockedCache { return c }
        let set = Set(KbPrefs.store.stringArray(forKey: blockedKey) ?? [])
        blockedCache = set
        return set
    }

    /// El usuario "olvida" una sugerencia: se borra de lo aprendido y no se
    /// vuelve a proponer.
    static func forget(_ word: String) {
        let clean = word.lowercased()
        lock.lock()
        var dict = wordsDict()
        dict[clean] = nil
        wordsCache = dict
        wordsDirty = true
        var bigrams = bigramsDict()
        for key in bigrams.keys where key.hasSuffix(" " + clean) || key.hasPrefix(clean + " ") {
            bigrams[key] = nil
        }
        bigramsCache = bigrams
        bigramsDirty = true
        var blocked = blockedCache ?? Set(KbPrefs.store.stringArray(forKey: blockedKey) ?? [])
        blocked.insert(clean)
        blockedCache = blocked
        lock.unlock()
        KbPrefs.store.set(Array(blocked.prefix(400)), forKey: blockedKey)
        flush()
    }

    static func learnedWords() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return wordsDict()
    }

    static func isKnown(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wordsDict()[word.lowercased()] != nil
    }

    static func learn(_ word: String) {
        let clean = word.lowercased()
        guard clean.count >= 2, clean.count <= 24,
              clean.rangeOfCharacter(from: .letters) != nil,
              clean.rangeOfCharacter(from: .decimalDigits) == nil else { return }
        lock.lock()
        var dict = wordsDict()
        dict[clean, default: 0] += 1
        if dict.count > 600 {
            // Poda: elimina las de menor frecuencia
            let sorted = dict.sorted { $0.value > $1.value }.prefix(500)
            dict = Dictionary(uniqueKeysWithValues: Array(sorted))
        }
        wordsCache = dict
        wordsDirty = true
        lock.unlock()
        scheduleFlush()
    }

    static func learnBigram(previous: String, next: String) {
        let key = previous.lowercased() + " " + next.lowercased()
        guard key.count <= 40 else { return }
        lock.lock()
        var dict = bigramsDict()
        dict[key, default: 0] += 1
        if dict.count > 2000 {
            let sorted = dict.sorted { $0.value > $1.value }.prefix(1600)
            dict = Dictionary(uniqueKeysWithValues: Array(sorted))
        }
        bigramsCache = dict
        bigramsDirty = true
        lock.unlock()
        scheduleFlush()
    }

    /// Palabras que suelen seguir a `word` según lo que ha escrito el usuario.
    static func successors(of word: String) -> [String] {
        let prefix = word.lowercased() + " "
        lock.lock()
        let dict = bigramsDict()
        lock.unlock()
        let blocked = blockedWords()
        return dict
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.value > $1.value }
            .map { String($0.key.dropFirst(prefix.count)) }
            .filter { !blocked.contains($0.lowercased()) }
            .prefix(3)
            .map { $0 }
    }

    /// Coincidencias del vocabulario aprendido para un prefijo.
    static func matches(prefix: String, limit: Int) -> [String] {
        let lower = prefix.lowercased()
        let blocked = blockedWords()
        lock.lock()
        let all = wordsDict()
        lock.unlock()
        return all
            .filter { $0.key.hasPrefix(lower) && $0.key != lower && !blocked.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    static func clear() {
        lock.lock()
        wordsCache = [:]
        bigramsCache = [:]
        wordsDirty = false
        bigramsDirty = false
        lock.unlock()
        KbPrefs.store.removeObject(forKey: wordsKey)
        KbPrefs.store.removeObject(forKey: bigramsKey)
    }

    // MARK: Gestión manual (pantalla de palabras aprendidas)

    /// Lista ordenada por frecuencia descendente.
    static func allWordsSorted() -> [(word: String, count: Int)] {
        learnedWords().sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (word: $0.key, count: $0.value) }
    }

    /// Añade o actualiza una palabra manualmente (y la desbloquea).
    @discardableResult
    static func addManual(_ word: String, count: Int = 5) -> Bool {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 2, clean.count <= 24,
              clean.rangeOfCharacter(from: .letters) != nil,
              !clean.contains(" ") else { return false }
        lock.lock()
        var dict = wordsDict()
        dict[clean] = max(count, dict[clean] ?? 0)
        wordsCache = dict
        wordsDirty = true
        var blocked = blockedCache ?? Set(KbPrefs.store.stringArray(forKey: blockedKey) ?? [])
        blocked.remove(clean)
        blockedCache = blocked
        lock.unlock()
        KbPrefs.store.set(Array(blocked), forKey: blockedKey)
        flush()
        return true
    }

    /// Renombra una palabra conservando su frecuencia.
    @discardableResult
    static func rename(_ old: String, to new: String) -> Bool {
        let from = old.lowercased()
        let to = new.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard to.count >= 2, to.count <= 24, to != from,
              to.rangeOfCharacter(from: .letters) != nil, !to.contains(" ") else { return false }
        lock.lock()
        var dict = wordsDict()
        let freq = dict[from] ?? 1
        dict[from] = nil
        dict[to] = max(freq, dict[to] ?? 0)
        wordsCache = dict
        wordsDirty = true
        lock.unlock()
        flush()
        return true
    }

    /// Elimina una palabra sin bloquearla (a diferencia de `forget`).
    static func remove(_ word: String) {
        let clean = word.lowercased()
        lock.lock()
        var dict = wordsDict()
        dict[clean] = nil
        wordsCache = dict
        wordsDirty = true
        lock.unlock()
        flush()
    }

    /// Palabras bloqueadas (no se sugieren) para poder gestionarlas.
    static func blockedList() -> [String] { blockedWords().sorted() }

    static func unblock(_ word: String) {
        let clean = word.lowercased()
        lock.lock()
        var blocked = blockedCache ?? Set(KbPrefs.store.stringArray(forKey: blockedKey) ?? [])
        blocked.remove(clean)
        blockedCache = blocked
        lock.unlock()
        KbPrefs.store.set(Array(blocked), forKey: blockedKey)
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
        "y": ["ý","ÿ"],
        "s": ["ß","§"],
        "?": ["¿","!","¡",".",","],
        "!": ["¡","?","¿",".",","],
        ".": ["…",",","?","!",";",":"],
        ",": [";",":","…"],
        "-": ["—","–","•","_","~"],
        "_": ["-","—","–"],
        "/": ["\\","|"],
        "(": ["[","{","<"],
        ")": ["]","}",">"],
        "\"": ["«","»","„","“","”"],
        "'": ["‘","’","`"],
        "$": ["€","£","¥","₩","¢","₿"],
        "&": ["§","¶"],
        "%": ["‰","℅"],
        "*": ["†","‡","★","•"],
        "+": ["±"],
        "=": ["≠","≈","≤","≥"],
        "@": ["ª","º"],
        "#": ["№"],
        ":": [";"],
        ";": [":"],
        "<": ["≤","«"],
        ">": ["≥","»"]
    ]
}
