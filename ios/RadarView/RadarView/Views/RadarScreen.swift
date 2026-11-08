import SwiftUI

/// The FIREFIGHTER side: one tactical radar screen that tracks the beacon phone like
/// Find My's Precision Finding.
struct RadarScreen: View {
    let store: RadarStore
    var onSwitchRole: (AppRole) -> Void = { _ in }
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            scope
            Hairline()
            footer
            controls
        }
        .padding(.horizontal, 16)
        .background(Color.black.ignoresSafeArea())
        .overlay { Scanlines().ignoresSafeArea() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLog) {
            LogSheet(store: store, onSwitchRole: onSwitchRole)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                tacText("FF-RADAR", 14, .bold).foregroundStyle(Theme.ink)
                tacText(stateLine, 11, .bold).foregroundStyle(stateColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 10) {
                    pip("W", store.boards.isReady(.waist))
                    pip("L", store.boards.isReady(.left))
                    pip("R", store.boards.isReady(.right))
                    pip("U", store.uwb.isLinked)
                }
                tacText("\(store.sourceKind.label) · 5M", 11).foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 12)
    }

    private var stateLine: String {
        if store.isOnTarget { return "ON TARGET" }
        switch store.status {
        case .tracking: return "TRACKING"
        case .lastKnown: return "LAST KNOWN"
        case .rangeOnly: return "RANGE ONLY"
        case .searching, .none: return "SEARCHING"
        }
    }

    private var stateColor: Color {
        if store.isOnTarget { return Theme.teal }
        switch store.status {
        case .tracking: return Theme.teal
        case .lastKnown, .rangeOnly: return Theme.ink
        case .searching, .none: return Theme.dim
        }
    }

    /// Connection pip: filled when connected, hollow when not.
    private func pip(_ letter: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? Theme.cyan : Color.clear)
                .overlay(Circle().stroke(on ? Theme.cyan : Theme.dim, lineWidth: 1))
                .frame(width: 7, height: 7)
            tacText(letter, 11, .bold).foregroundStyle(on ? Theme.ink : Theme.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(letter) \(on ? "connected" : "not connected")")
    }

    // MARK: Scope

    private var scope: some View {
        TimelineView(.animation) { tl in
            let snap = ScopeSnapshot(
                heading: store.displayHeading,
                origin: store.origin,
                providesBearing: store.providesBearing,
                track: store.track,
                range: store.range,
                status: store.status,
                onTarget: store.isOnTarget,
                aligned: aligned,
                blips: store.blips,
                obstacleCm: store.obstacleCm,
                obstacleVisibility: store.obstacleVisibility,
                halfAngle: RadarStore.halfAngle,
                maxRange: RadarStore.range)
            let date = tl.date
            Canvas { ctx, size in
                ScopeRenderer(s: snap, now: date, size: size).draw(ctx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// Facing the target: |bearing| ≤ 15° with a live fix.
    private var aligned: Bool {
        guard store.status == .tracking, let r = store.relativeBearing else { return false }
        return abs(r) <= 15
    }

    private var accessibilitySummary: String {
        guard let d = store.shownDistance else { return "Searching. Move around and sweep slowly." }
        return String(format: "Target %.1f metres, %@. Bracelets: %@.", d, directionLine, cueText)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if store.isOnTarget, let d = store.countedDistance {
            centeredFooter(String(format: "ON TARGET · %.1f M", d), color: Theme.teal, glow: true)
        } else if store.shownDistance == nil {
            centeredFooter("MOVE AROUND · SWEEP SLOWLY", color: Theme.ink, glow: false)
        } else {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.countedDistance.map { String(format: "%.1f M", $0) } ?? "--")
                        .font(.system(size: 44, weight: .medium, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(store.status == .tracking ? Theme.ink : Theme.dim)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    tacText(directionLine, 12, .bold)
                        .foregroundStyle(aligned ? Theme.teal : (store.status == .tracking ? Theme.ink : Theme.dim))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                infoColumn(alignment: .trailing)
            }
            .padding(.vertical, 12)
        }
    }

    private func centeredFooter(_ text: String, color: Color, glow: Bool) -> some View {
        VStack(spacing: 8) {
            tacText(text, 22, .bold)
                .foregroundStyle(color)
                .glow(glow ? color : .clear, radius: 4)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 12) {
                cueLabel
                rxLabel
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func infoColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            cueLabel
            rxLabel
        }
        .layoutPriority(1)
    }

    /// The cue actually being sent to the bracelets.
    private var cueLabel: some View {
        let rule = store.guidance.rule
        let color: Color = rule == .stop ? Theme.red : (rule == .onTarget ? Theme.teal : Theme.ink)
        return tacText(cueText, 14, .bold).foregroundStyle(color).lineLimit(1)
    }

    private var cueText: String {
        switch store.guidance.rule {
        case .stop: "STOP"
        case .onTarget: "ON TARGET"
        case .left: "TURN LEFT"
        case .right: "TURN RIGHT"
        case .forward: "FORWARD"
        case .sweep, .idle: "SEARCHING"
        }
    }

    private var rxLabel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let us = store.boards.currentUS(now: tl.date)
            let usText = us.map { $0 < 0 ? "US --" : "US \($0)" } ?? "US --"
            let rx = store.boards.waistRate > 0 ? "RX \(Int(store.boards.waistRate.rounded()))Hz" : "RX --"
            tacText("\(usText) · \(rx)", 11)
                .foregroundStyle(us.map { $0 > 0 && $0 < 60 } == true ? Theme.red : Theme.dim)
                .lineLimit(1)
        }
    }

    /// Find My-style direction words plus degrees: "TO YOUR LEFT · 48°".
    private var directionLine: String {
        guard store.providesBearing else { return "RANGE ONLY · NO BEARING" }
        guard let r = store.relativeBearing else { return "NO DIRECTION YET" }
        let words = Self.directionWords(r)
        return store.status == .lastKnown
            ? "LAST KNOWN · \(words) · \(Int(abs(r).rounded()))°"
            : "\(words) · \(Int(abs(r).rounded()))°"
    }

    static func directionWords(_ r: Double) -> String {
        let a = abs(r)
        let side = r < 0 ? "LEFT" : "RIGHT"
        switch a {
        case ...15: return "AHEAD"
        case ...45: return "AHEAD · SLIGHTLY \(side)"
        case ...135: return "TO YOUR \(side)"
        default: return "BEHIND YOU"
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            Button {
                store.toggleScan()
            } label: {
                TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                    let on = !store.scanning || tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.6
                    tacText(store.scanning ? "[SCANNING]" : "[SCAN]", 13, .bold)
                        .foregroundStyle(store.scanning ? Theme.ping : Theme.line)
                        .opacity(on ? 1 : 0.3)
                }
                .frame(minWidth: 110, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(store.scanning ? "Stop scanning and clear dots" : "Start scanning")

            Spacer()

            Button {
                store.cycleSource()
            } label: {
                tacText("[SRC \(store.sourceKind.label)]", 13, .bold)
                    .foregroundStyle(Theme.line)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Target source \(store.sourceKind.label). Tap to change.")

            Spacer()

            Button {
                showLog = true
            } label: {
                tacText("[LOG]", 13, .bold)
                    .foregroundStyle(Theme.line)
                    .frame(minWidth: 110, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open log")
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

// MARK: - Drawing

struct ScopeSnapshot {
    let heading: Double
    let origin: CGPoint
    let providesBearing: Bool
    let track: TrackSnapshot
    let range: RangeDisplay
    let status: TrackStatus
    let onTarget: Bool
    let aligned: Bool
    let blips: [Blip]
    let obstacleCm: Double
    let obstacleVisibility: Double
    let halfAngle: Double
    let maxRange: Double
}

/// Heading-up polar scope: me at the bottom centre, up = where the phone points.
/// The target lives in world coordinates and is drawn relative to the current heading.
struct ScopeRenderer {
    let s: ScopeSnapshot
    let now: Date
    let size: CGSize

    private var time: Double { now.timeIntervalSinceReferenceDate }

    private var radius: CGFloat {
        let byWidth = (size.width / 2 - 4) / CGFloat(sin(s.halfAngle * .pi / 180))
        let byHeight = size.height - 40
        return max(40, min(byWidth, byHeight))
    }

    private var origin: CGPoint {
        CGPoint(x: size.width / 2, y: min(size.height - 16, size.height / 2 + radius / 2 + 8))
    }

    private var ppm: CGFloat { radius / CGFloat(s.maxRange) }

    func draw(_ ctx: GraphicsContext) {
        if s.aligned { drawAlignedTint(ctx) }
        drawGrid(ctx)
        drawPing(ctx)
        drawNoise(ctx)
        drawBlips(ctx)
        drawObstacle(ctx)
        if s.providesBearing { drawTrackedTarget(ctx) } else { drawRangeTarget(ctx) }
        drawOrigin(ctx)
    }

    // MARK: Grid

    private func drawAlignedTint(_ ctx: GraphicsContext) {
        ctx.fill(wedge(), with: .color(Theme.teal.opacity(0.05)))
    }

    private func drawGrid(_ ctx: GraphicsContext) {
        let h = s.halfAngle
        var radials = Path()
        for i in 0..<5 where i != 2 {
            let a = -h + 2 * h * Double(i) / 4
            radials.move(to: origin)
            radials.addLine(to: point(a, s.maxRange))
        }
        var rings = Path()
        for m in 1...Int(s.maxRange) { rings.addPath(arc(Double(m))) }
        ctx.stroke(radials, with: .color(Theme.grid), lineWidth: 1)
        ctx.stroke(rings, with: .color(Theme.grid.opacity(0.75)), lineWidth: 1)

        // Centre line: brightens teal when you're facing the target.
        var centre = Path()
        centre.move(to: origin)
        centre.addLine(to: point(0, s.maxRange))
        if s.aligned {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 3))
                layer.stroke(centre, with: .color(Theme.teal.opacity(0.8)), lineWidth: 3)
            }
            ctx.stroke(centre, with: .color(Theme.teal), lineWidth: 1.5)
        } else {
            ctx.stroke(centre, with: .color(Theme.grid), lineWidth: 1)
        }

        for m in 1...Int(s.maxRange) {
            ctx.draw(Text("\(m)M")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Theme.dim),
                     at: CGPoint(x: origin.x + 5, y: origin.y - CGFloat(m) * ppm - 7), anchor: .leading)
        }
    }

    /// Two tiny fixed noise dots.
    private func drawNoise(_ ctx: GraphicsContext) {
        for (a, m) in [(-27.0, 3.6), (19.0, 1.8)] {
            let p = point(a, m)
            ctx.fill(Path(CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)), with: .color(Theme.ink.opacity(0.35)))
        }
    }

    // MARK: Ping

    /// A band of 5 thin light-blue arcs, 6 pt apart, launching from the origin and
    /// expanding to the edge in ~0.6 s (ease-out), relaunching every ~0.75 s.
    /// Searching: 1.5 s cycle, dim. On target: teal-green.
    private func drawPing(_ ctx: GraphicsContext) {
        let searching = s.status == .searching || s.status == .none
        let cycle = searching ? 1.5 : 0.75
        let launch = searching ? 1.2 : 0.6
        let e = time.truncatingRemainder(dividingBy: cycle)
        guard e < launch else { return }
        let u = e / launch
        let eased = 1 - pow(1 - u, 3)
        let lead = CGFloat(eased) * radius
        let color = s.onTarget ? Theme.teal : Theme.ping
        let base = (searching ? 0.4 : 0.85) * (1 - 0.35 * u)
        let weights = [1.0, 0.75, 0.55, 0.38, 0.24]
        var arcs: [(Path, Double)] = []
        for (i, w) in weights.enumerated() {
            let r = lead - CGFloat(i) * 6
            guard r > 4 else { continue }
            arcs.append((arcPoints(r), base * w))
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.5))
            for (p, a) in arcs { layer.stroke(p, with: .color(color.opacity(a * 0.6)), lineWidth: 2) }
        }
        for (p, a) in arcs { ctx.stroke(p, with: .color(color.opacity(a)), lineWidth: 1) }
    }

    // MARK: SCAN dots

    private func drawBlips(_ ctx: GraphicsContext) {
        for b in s.blips {
            guard let p = screenPoint(world: b.position) else { continue }
            let alpha = max(0, 1 - now.timeIntervalSince(b.time) / RadarStore.blipLifetime)
            ctx.fill(Path(CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                     with: .color(Theme.ping.opacity(alpha * 0.8)))
        }
    }

    // MARK: Obstacle

    private func drawObstacle(_ ctx: GraphicsContext) {
        guard s.obstacleVisibility > 0.02 else { return }
        let meters = min(s.obstacleCm / 100, s.maxRange)
        let close = s.obstacleCm < 60
        let color = close ? Theme.red : Theme.ink
        let a = s.obstacleVisibility * (close ? 1 : 0.75)
        let bar = arc(meters, from: -12, to: 12)
        ctx.stroke(bar, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
        ctx.draw(Text("\(Int(s.obstacleCm.rounded()))CM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(color.opacity(a)),
                 at: point(14, meters), anchor: .leading)
    }

    // MARK: Target 01

    private func drawTrackedTarget(_ ctx: GraphicsContext) {
        let t = s.track
        guard let pos = t.position else {
            if t.status == .rangeOnly, let d = t.distance {
                ctx.stroke(arc(min(d, s.maxRange)), with: .color(Theme.ink.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            return
        }
        let live = t.status == .tracking
        let a = live ? 1.0 : 0.4
        let rel = Compass.delta(Compass.bearing(from: s.origin, to: pos), s.heading)
        let d = s.origin.distance(to: pos)

        drawTrail(ctx, alpha: a)
        let p = point(rel, min(d, s.maxRange))
        if contains(p) {
            drawMarker(ctx, at: p, alpha: a, label: live ? "01" : "01 · LAST KNOWN")
        }
        if abs(rel) > s.halfAngle {
            drawChevron(ctx, toward: rel, alpha: a)
        }
    }

    /// Thin dotted tail of the last ~1.5 s, fading with age.
    private func drawTrail(_ ctx: GraphicsContext, alpha a: Double) {
        let history = s.track.trail.dropLast()
        guard !history.isEmpty else { return }
        let n = Double(history.count)
        for (i, w) in history.enumerated() {
            guard let p = screenPoint(world: w) else { continue }
            let fresh = (Double(i) + 1) / n
            let r = 1.0 + 0.9 * fresh
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(Theme.teal.opacity((0.12 + 0.5 * fresh) * a)))
        }
    }

    /// Radar source: distance only → marker on the centre line.
    private func drawRangeTarget(_ ctx: GraphicsContext) {
        guard s.range.visibility > 0.02 else { return }
        drawMarker(ctx, at: point(0, min(s.range.distance, s.maxRange)), alpha: s.range.visibility, label: "01")
    }

    /// ~14 pt circle with a "+" crosshair, teal-green, soft static glow; label to the right.
    private func drawMarker(_ ctx: GraphicsContext, at p: CGPoint, alpha a: Double, label: String) {
        let ring = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - 4, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 4, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - 4)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 4))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)),
                       with: .color(Theme.teal.opacity(0.35 * a)))
        }
        ctx.stroke(ring, with: .color(Theme.teal.opacity(a)), lineWidth: 1.5)
        ctx.stroke(cross, with: .color(Theme.teal.opacity(a)), lineWidth: 1.5)

        let onLeft = p.x > size.width - 120
        ctx.draw(Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.teal.opacity(max(a, 0.6))),
                 at: CGPoint(x: onLeft ? p.x - 15 : p.x + 15, y: p.y),
                 anchor: onLeft ? .trailing : .leading)
    }

    /// Bold chevron on the wedge edge, pointing the way to turn.
    private func drawChevron(_ ctx: GraphicsContext, toward rel: Double, alpha a: Double) {
        let left = rel < 0
        let edge = left ? -s.halfAngle : s.halfAngle
        let c = point(edge, s.maxRange * 0.55)
        // Points outward, perpendicular to the edge (the turning direction).
        let out = Compass.unit(edge + (left ? -90 : 90))
        let back = Compass.unit(edge + (left ? 90 : -90))
        let tip = CGPoint(x: c.x + out.dx * 9, y: c.y + out.dy * 9)
        let along = Compass.unit(edge)
        let w1 = CGPoint(x: c.x + back.dx * 3 + along.dx * 11, y: c.y + back.dy * 3 + along.dy * 11)
        let w2 = CGPoint(x: c.x + back.dx * 3 - along.dx * 11, y: c.y + back.dy * 3 - along.dy * 11)
        var chev = Path()
        chev.move(to: w1)
        chev.addLine(to: tip)
        chev.addLine(to: w2)
        let color = Theme.teal.opacity(a)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(chev, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(chev, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        ctx.draw(Text("\(Int(abs(rel).rounded()))°")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(color),
                 at: CGPoint(x: tip.x + out.dx * 18, y: tip.y + out.dy * 18))
    }

    /// Small triangle at the bottom centre: me.
    private func drawOrigin(_ ctx: GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: origin.x, y: origin.y - 7))
        p.addLine(to: CGPoint(x: origin.x - 5, y: origin.y + 3))
        p.addLine(to: CGPoint(x: origin.x + 5, y: origin.y + 3))
        p.closeSubpath()
        ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
    }

    // MARK: Helpers

    private func point(_ relBearing: Double, _ meters: Double) -> CGPoint {
        let u = Compass.unit(relBearing)
        let r = CGFloat(meters) * ppm
        return CGPoint(x: origin.x + u.dx * r, y: origin.y + u.dy * r)
    }

    private func screenPoint(world w: CGPoint) -> CGPoint? {
        let d = s.origin.distance(to: w)
        guard d <= s.maxRange + 0.5 else { return nil }
        let rel = Compass.delta(Compass.bearing(from: s.origin, to: w), s.heading)
        let p = point(rel, d)
        return contains(p) ? p : nil
    }

    private func contains(_ p: CGPoint) -> Bool {
        p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height
    }

    private func wedge() -> Path {
        var p = Path()
        p.move(to: origin)
        p.addPath(arc(s.maxRange))
        p.addLine(to: origin)
        p.closeSubpath()
        return p
    }

    private func arc(_ meters: Double, from b0: Double? = nil, to b1: Double? = nil) -> Path {
        arcPoints(CGFloat(meters) * ppm, from: b0, to: b1)
    }

    /// Arc across the wedge (or [b0, b1]) at a radius in points.
    private func arcPoints(_ r: CGFloat, from b0: Double? = nil, to b1: Double? = nil) -> Path {
        let lo = b0 ?? -s.halfAngle
        let hi = b1 ?? s.halfAngle
        var p = Path()
        let steps = 36
        for i in 0...steps {
            let u = Compass.unit(lo + (hi - lo) * Double(i) / Double(steps))
            let pt = CGPoint(x: origin.x + u.dx * r, y: origin.y + u.dy * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
