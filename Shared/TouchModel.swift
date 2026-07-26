import Foundation
import CoreGraphics

/// Modelo de cómo teclea el usuario.
///
/// Nadie toca justo en el centro de las teclas: cada persona tiene un sesgo
/// propio y distinto en cada tecla (con el pulgar derecho se tiende a caer a la
/// izquierda de las teclas de la derecha, la fila de abajo se toca más arriba,
/// etc.). Aquí se guarda ese sesgo por letra, medido como fracción del tamaño
/// de la tecla, y sirve para dos cosas: mover las fronteras invisibles entre
/// teclas y afinar el autocorrector.
///
/// Todo se calcula y se guarda en el dispositivo.
enum TouchModel {

    static let key = "kb.touchModel"      // [letra: [sesgoX, sesgoY, muestras]]

    private static let lock = NSLock()
    private static var cache: [String: [Double]]?
    private static var dirty = false
    private static var flushScheduled = false

    private static func dict() -> [String: [Double]] {
        if let c = cache { return c }
        let d = KbPrefs.store.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        cache = d
        return d
    }

    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { flush() }
    }

    static func flush() {
        lock.lock()
        let snapshot = dirty ? cache : nil
        dirty = false
        flushScheduled = false
        lock.unlock()
        if let snapshot { KbPrefs.store.set(snapshot, forKey: key) }
    }

    static func invalidateCache() {
        lock.lock(); cache = nil; lock.unlock()
    }

    /// Anota una pulsación: desvío respecto al centro nominal de la tecla,
    /// en fracción de su tamaño (0.5 = justo en el borde).
    ///
    /// `weight` sube cuando la señal es fuerte, por ejemplo cuando el usuario
    /// borra una letra y la sustituye por su vecina: ahí sabemos con certeza
    /// que ese toque debía haber caído en la otra tecla.
    static func record(_ letter: Character, dx: Double, dy: Double, weight: Double = 1) {
        guard dx.isFinite, dy.isFinite, abs(dx) <= 1.5, abs(dy) <= 1.5 else { return }
        let k = String(letter)
        lock.lock()
        var d = dict()
        var entry = d[k] ?? [0, 0, 0]
        let n = entry[2]
        // Media móvil: rápida al principio, estable después.
        let alpha = min(1.0, max(0.03, weight / (n + 1)))
        entry[0] += (dx - entry[0]) * alpha
        entry[1] += (dy - entry[1]) * alpha
        entry[2] = min(n + weight, 5000)
        d[k] = entry
        cache = d
        dirty = true
        lock.unlock()
        scheduleFlush()
    }

    /// Sesgo aprendido de una letra, ya recortado para que nunca desplace la
    /// frontera más de un tercio de tecla.
    static func bias(_ letter: Character) -> (x: Double, y: Double, samples: Double) {
        lock.lock()
        let entry = dict()[String(letter)]
        lock.unlock()
        guard let entry, entry.count == 3 else { return (0, 0, 0) }
        let limit = 0.33
        return (min(max(entry[0], -limit), limit),
                min(max(entry[1], -limit), limit),
                entry[2])
    }

    /// Muestras totales: sirve para no aplicar nada hasta tener datos de sobra.
    static var totalSamples: Double {
        lock.lock(); defer { lock.unlock() }
        return dict().values.reduce(0) { $0 + ($1.count == 3 ? $1[2] : 0) }
    }

    /// Letras con datos suficientes, ordenadas por desvío (para la pantalla de
    /// ajustes).
    static func summary() -> [(letter: String, dx: Double, dy: Double, samples: Int)] {
        lock.lock()
        let d = dict()
        lock.unlock()
        return d.compactMap { k, v in
            guard v.count == 3, v[2] >= 5 else { return nil }
            return (letter: k, dx: v[0], dy: v[1], samples: Int(v[2]))
        }
        .sorted { abs($0.dx) + abs($0.dy) > abs($1.dx) + abs($1.dy) }
    }

    static func reset() {
        lock.lock()
        cache = [:]
        dirty = false
        lock.unlock()
        KbPrefs.store.removeObject(forKey: key)
    }
}
