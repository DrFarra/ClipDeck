import Foundation

/// Velocidad real al escribir, con y sin autocorrección, para comparar.
///
/// Sólo números: ni texto ni palabras. El teclado los anota y la app los
/// enseña en Ajustes del teclado. El tiempo es el de escritura activa: las
/// pausas de más de unos segundos (pensar, leer la respuesta) no cuentan.
enum TypingStats {

    struct Totals: Codable, Equatable {
        var keys = 0
        var words = 0
        var backspaces = 0
        var corrections = 0
        var undone = 0
        /// Segundos escribiendo.
        var seconds = 0.0

        /// nil hasta que hay medio minuto escribiendo: antes no dice nada.
        var wordsPerMinute: Double? { seconds >= 30 ? Double(words) / (seconds / 60) : nil }
        var backspacesPerWord: Double? { words > 0 ? Double(backspaces) / Double(words) : nil }
        var undoneShare: Double? { corrections > 0 ? Double(undone) / Double(corrections) : nil }
    }

    enum Event { case key, word, backspace, correction, undone }

    /// Más que esto entre dos pulsaciones ya es una pausa, no escritura.
    static let maxGap = 3.0

    /// Suma un evento ocurrido `gap` segundos después del anterior.
    static func apply(_ event: Event, to t: inout Totals, gap: Double?) {
        if let gap, gap > 0, gap <= maxGap { t.seconds += gap }
        switch event {
        case .key: t.keys += 1
        case .word: t.words += 1
        case .backspace: t.backspaces += 1
        case .correction: t.corrections += 1
        case .undone: t.undone += 1
        }
    }

    // MARK: Almacenamiento (App Group)

    private static func key(_ corrector: Bool) -> String { corrector ? "kb.stats.on" : "kb.stats.off" }

    static func totals(corrector: Bool) -> Totals {
        guard let data = KbPrefs.store.data(forKey: key(corrector)),
              let t = try? JSONDecoder().decode(Totals.self, from: data) else { return Totals() }
        return t
    }

    static func reset() {
        KbPrefs.store.removeObject(forKey: key(true))
        KbPrefs.store.removeObject(forKey: key(false))
    }

    // MARK: En el teclado (hilo principal)

    private static var pending: [Bool: Totals] = [:]
    private static var last: TimeInterval?
    private static var flushScheduled = false

    static func record(_ event: Event, corrector: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        var t = pending[corrector] ?? Totals()
        apply(event, to: &t, gap: last.map { now - $0 })
        pending[corrector] = t
        last = now
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { flush() }
    }

    /// Suma lo pendiente a lo guardado.
    static func flush() {
        flushScheduled = false
        for (corrector, delta) in pending {
            var t = totals(corrector: corrector)
            t.keys += delta.keys
            t.words += delta.words
            t.backspaces += delta.backspaces
            t.corrections += delta.corrections
            t.undone += delta.undone
            t.seconds += delta.seconds
            if let data = try? JSONEncoder().encode(t) { KbPrefs.store.set(data, forKey: key(corrector)) }
        }
        pending = [:]
    }
}
