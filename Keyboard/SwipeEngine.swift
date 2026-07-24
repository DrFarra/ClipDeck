import UIKit

// MARK: - Reconocedor de escritura deslizando
//
// No existe API de Apple para esto, así que el reconocimiento es propio y sigue
// el enfoque clásico de comparación de formas:
//
//   1. El trazo del dedo se limpia y se re-muestrea a N puntos equidistantes.
//   2. Se marca qué teclas rozó el trazo (una máscara de 27 bits).
//   3. Cada palabra del vocabulario tiene su propia máscara: si contiene una
//      letra que el dedo nunca rozó, se descarta con una sola operación entera.
//      Esto elimina más del 95% de los candidatos en microsegundos.
//   4. De las que sobreviven se construye su "trazo ideal" (la línea que une
//      los centros de sus teclas), se re-muestrea igual y se mide la distancia
//      media punto a punto con el trazo real.
//   5. Se ordena por esa distancia, con bonificación para las palabras que el
//      usuario ya escribió y las de uso frecuente.

enum SwipeRecognizer {

    static let sampleCount = 26

    static func recognize(points raw: [CGPoint],
                          keyCenters: [UInt8: CGPoint],
                          pitch: CGFloat,
                          limit: Int = 4) -> [String] {

        let lex = SwipeLexicon.shared
        guard lex.isLoaded, pitch > 1 else { return [] }

        let path = simplify(raw)
        guard path.count >= 3 else { return [] }
        let userLen = pathLength(path)
        guard userLen > pitch * 0.9 else { return [] }

        var user = [CGPoint](repeating: .zero, count: sampleCount)
        resample(path, count: sampleCount, into: &user)

        // Teclas rozadas por el trazo.
        var nearMask: UInt32 = 0
        let radius = pitch * 0.72
        for (idx, c) in keyCenters where minDistance(from: c, to: path) <= radius {
            nearMask |= (UInt32(1) << UInt32(idx))
        }
        guard nearMask.nonzeroBitCount >= 2 else { return [] }

        let firstMask = maskOfNearest(to: path[0], in: keyCenters, k: 3, maxDist: pitch * 1.15)
        let lastMask = maskOfNearest(to: path[path.count - 1], in: keyCenters, k: 3, maxDist: pitch * 1.15)
        guard firstMask != 0, lastMask != 0 else { return [] }

        var ideal = [CGPoint](repeating: .zero, count: sampleCount)
        var nodes = [CGPoint]()
        nodes.reserveCapacity(20)

        var scored: [(score: Double, index: Int)] = []
        scored.reserveCapacity(64)

        let n = lex.count
        let flat = lex.flat
        let starts = lex.starts
        let lens = lex.lens
        let masks = lex.masks
        let priors = lex.priors

        for i in 0..<n {
            let m = masks[i]
            if (m & ~nearMask) != 0 { continue }
            let len = Int(lens[i])
            if len < 2 { continue }
            let s = Int(starts[i])
            if (firstMask & (UInt32(1) << UInt32(flat[s]))) == 0 { continue }
            if (lastMask & (UInt32(1) << UInt32(flat[s + len - 1]))) == 0 { continue }

            nodes.removeAll(keepingCapacity: true)
            var previous: UInt8 = 255
            var ok = true
            for k in 0..<len {
                let letter = flat[s + k]
                if letter == previous { continue }
                previous = letter
                guard let c = keyCenters[letter] else { ok = false; break }
                nodes.append(c)
            }
            guard ok, nodes.count >= 2 else { continue }

            resample(nodes, count: sampleCount, into: &ideal)

            var sum: CGFloat = 0
            for k in 0..<sampleCount {
                sum += hypot(user[k].x - ideal[k].x, user[k].y - ideal[k].y)
            }
            var score = Double(sum / CGFloat(sampleCount) / pitch)

            // Penaliza que el recorrido total difiera mucho del real.
            let idealLen = pathLength(nodes)
            score += Double(abs(idealLen - userLen) / max(userLen, 1)) * 0.30

            // Bonifica lo que el usuario ya usa y lo muy frecuente.
            score -= Double(priors[i]) / 255.0 * 0.34

            if score < 1.4 { scored.append((score, i)) }
        }

        guard !scored.isEmpty else { return [] }
        scored.sort { $0.score < $1.score }
        guard scored[0].score < 1.05 else { return [] }

        var out: [String] = []
        var seen = Set<String>()
        for entry in scored {
            let w = lex.words[entry.index]
            if seen.contains(w) { continue }
            seen.insert(w)
            out.append(w)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Geometría

    /// Longitud total del trazo (para distinguir un deslizamiento real de un
    /// toque con el dedo movido).
    static func traceLength(_ pts: [CGPoint]) -> CGFloat { pathLength(pts) }

    private static func simplify(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(pts.count)
        for p in pts {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < 2 { continue }
            out.append(p)
        }
        if out.count < 2, let f = pts.first { out = [f, f] }
        return out
    }

    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count {
            total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        return total
    }

    private static func resample(_ pts: [CGPoint], count n: Int, into out: inout [CGPoint]) {
        guard n > 1, let first = pts.first, let last = pts.last else { return }
        let total = pathLength(pts)
        guard total > 0.001 else {
            for i in 0..<n { out[i] = first }
            return
        }
        let step = total / CGFloat(n - 1)
        out[0] = first
        var slot = 1
        var carried: CGFloat = 0
        var prev = first
        var i = 1
        while i < pts.count && slot < n - 1 {
            let cur = pts[i]
            let seg = hypot(cur.x - prev.x, cur.y - prev.y)
            if seg <= 0.0001 { i += 1; prev = cur; continue }
            if carried + seg >= step {
                let t = (step - carried) / seg
                let np = CGPoint(x: prev.x + t * (cur.x - prev.x),
                                 y: prev.y + t * (cur.y - prev.y))
                out[slot] = np
                slot += 1
                prev = np
                carried = 0
            } else {
                carried += seg
                prev = cur
                i += 1
            }
        }
        while slot < n { out[slot] = last; slot += 1 }
    }

    /// Distancia mínima de un punto a la polilínea (no sólo a sus vértices).
    private static func minDistance(from p: CGPoint, to path: [CGPoint]) -> CGFloat {
        guard path.count > 1 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<path.count {
            let d = distance(p, segmentA: path[i - 1], b: path[i])
            if d < best { best = d }
        }
        return best
    }

    private static func distance(_ p: CGPoint, segmentA a: CGPoint, b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let wx = p.x - a.x, wy = p.y - a.y
        let len2 = vx * vx + vy * vy
        if len2 <= 0.0001 { return hypot(wx, wy) }
        var t = (wx * vx + wy * vy) / len2
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
    }

    private static func maskOfNearest(to p: CGPoint, in centers: [UInt8: CGPoint],
                                      k: Int, maxDist: CGFloat) -> UInt32 {
        var list: [(CGFloat, UInt8)] = []
        list.reserveCapacity(centers.count)
        for (idx, c) in centers {
            let d = hypot(p.x - c.x, p.y - c.y)
            if d <= maxDist { list.append((d, idx)) }
        }
        list.sort { $0.0 < $1.0 }
        var mask: UInt32 = 0
        for entry in list.prefix(k) { mask |= (UInt32(1) << UInt32(entry.1)) }
        return mask
    }
}

// MARK: - Estela del trazo

final class SwipeTrailView: UIView {

    private let shape = CAShapeLayer()
    private var points: [CGPoint] = []
    private let maxPoints = 46

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shape.fillColor = nil
        shape.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55).cgColor
        shape.lineWidth = 5
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
    }

    func begin(at p: CGPoint) {
        points = [p]
        alpha = 1
        isHidden = false
        redraw()
    }

    func add(_ p: CGPoint) {
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
        points.append(p)
        if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
        redraw()
    }

    /// Desvanece la estela sin cortarla de golpe.
    func finish() {
        UIView.animate(withDuration: 0.18, animations: { self.alpha = 0 }) { _ in
            self.isHidden = true
            self.points = []
            self.shape.path = nil
            self.alpha = 1
        }
    }

    func cancel() {
        isHidden = true
        points = []
        shape.path = nil
        alpha = 1
    }

    private func redraw() {
        guard points.count > 1 else { shape.path = nil; return }
        let path = UIBezierPath()
        path.move(to: points[0])
        for i in 1..<points.count { path.addLine(to: points[i]) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path.cgPath
        CATransaction.commit()
    }
}
