import Foundation

/// Bearing fallback when UWB gives distance but no direction: pair each NI distance with
/// where I was (ARKit camera position, or step dead-reckoning) and, once my positions
/// span ≥ 0.8 m, solve for the beacon position by least squares.
///
/// - Positions spread in 2D: full least-squares fix (one answer).
/// - Positions along a line (walking straight): the along-track position is solved exactly,
///   but left/right of the line is mirror-ambiguous, so both candidates are returned and
///   the caller picks the one nearest the latched bearing.
struct Trilaterator {
    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    var window: TimeInterval = 8
    /// Positions must span at least this far (meters) before solving.
    var minSpan = 0.8
    /// Keep a new sample only once I've moved this far (NI runs at ~50 Hz).
    var minStep = 0.05
    /// Spread across the weakest axis (std dev, m) needed for an unambiguous 2D fix.
    var minLateral = 0.15
    /// Reject solutions whose distances don't fit (RMS residual, meters).
    var maxResidual = 0.5

    private var samples: [(p: Point, d: Double, t: Date)] = []

    mutating func reset() { samples.removeAll() }

    var count: Int { samples.count }

    /// Largest distance between any sample and the first one.
    var span: Double {
        guard let first = samples.first else { return 0 }
        return samples.map { hypot($0.p.x - first.p.x, $0.p.y - first.p.y) }.max() ?? 0
    }

    mutating func add(position p: Point, distance d: Double, at t: Date) {
        samples.removeAll { t.timeIntervalSince($0.t) > window }
        if let last = samples.last, hypot(p.x - last.p.x, p.y - last.p.y) < minStep { return }
        samples.append((p, d, t))
        if samples.count > 160 { samples.removeFirst(samples.count - 160) }
    }

    /// Candidate beacon positions (one if unambiguous, two mirror images if collinear),
    /// or empty if the geometry isn't good enough yet.
    func solve() -> [Point] {
        guard samples.count >= 5, span >= minSpan else { return [] }
        let n = Double(samples.count)
        let mx = samples.reduce(0) { $0 + $1.p.x } / n
        let my = samples.reduce(0) { $0 + $1.p.y } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for s in samples {
            let dx = s.p.x - mx, dy = s.p.y - my
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        sxx /= n; sxy /= n; syy /= n
        let tr = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr - 4 * det).squareRoot()
        let minEig = (tr - disc) / 2
        let maxEig = (tr + disc) / 2

        let candidates: [Point]
        if minEig.squareRoot() >= minLateral {
            candidates = solve2D(mx: mx, my: my).map { [$0] } ?? []
        } else {
            // Principal axis u (direction of travel) and its normal v.
            var ux = sxy, uy = maxEig - sxx
            if abs(ux) + abs(uy) < 1e-9 { ux = maxEig - syy; uy = sxy }
            if abs(ux) + abs(uy) < 1e-9 { ux = 1; uy = 0 }
            let ul = hypot(ux, uy)
            ux /= ul; uy /= ul
            let vx = -uy, vy = ux
            // d² = (s − a)² + c²  →  d² − s² = −2a·s + (a² + c²): linear in s.
            var ss = 0.0, sy = 0.0, s2 = 0.0, s1 = 0.0
            for smp in samples {
                let s = (smp.p.x - mx) * ux + (smp.p.y - my) * uy
                let y = smp.d * smp.d - s * s
                s1 += s; ss += s * s; sy += s * y; s2 += y
            }
            let denom = n * ss - s1 * s1
            guard abs(denom) > 1e-9 else { return [] }
            let slope = (n * sy - s1 * s2) / denom
            let k = (s2 - slope * s1) / n
            let a = -slope / 2
            let c = max(0, k - a * a).squareRoot()
            let base = Point(x: mx + a * ux, y: my + a * uy)
            // c also absorbs the height difference between the phones (assume ~0.5 m).
            // Beside the foot point the geometry says nothing: no answer. Otherwise collapse to
            // "ahead" by angle only.
            let newest = samples[samples.count - 1].p
            let sLast = (newest.x - mx) * ux + (newest.y - my) * uy
            let along = abs(a - sLast)
            guard along >= 0.5 else { return [] }
            let lateral = max(0, c * c - 0.25).squareRoot()
            candidates = atan2(lateral, along) < 12 * Double.pi / 180
                ? [base]
                : [Point(x: base.x + lateral * vx, y: base.y + lateral * vy),
                   Point(x: base.x - lateral * vx, y: base.y - lateral * vy)]
        }
        return candidates.filter { residual($0) <= maxResidual }
    }

    private func solve2D(mx: Double, my: Double) -> Point? {
        let n = Double(samples.count)
        let meanP2 = samples.reduce(0) { $0 + $1.p.x * $1.p.x + $1.p.y * $1.p.y } / n
        let meanD2 = samples.reduce(0) { $0 + $1.d * $1.d } / n
        var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
        for s in samples {
            let ax = 2 * (s.p.x - mx), ay = 2 * (s.p.y - my)
            let b = (s.p.x * s.p.x + s.p.y * s.p.y - meanP2) - (s.d * s.d - meanD2)
            a11 += ax * ax; a12 += ax * ay; a22 += ay * ay
            b1 += ax * b; b2 += ay * b
        }
        let dA = a11 * a22 - a12 * a12
        guard abs(dA) > 1e-9 else { return nil }
        return Point(x: (a22 * b1 - a12 * b2) / dA, y: (a11 * b2 - a12 * b1) / dA)
    }

    private func residual(_ t: Point) -> Double {
        let n = Double(samples.count)
        return (samples.reduce(0) { acc, s in
            let e = hypot(s.p.x - t.x, s.p.y - t.y) - s.d
            return acc + e * e
        } / n).squareRoot()
    }
}
