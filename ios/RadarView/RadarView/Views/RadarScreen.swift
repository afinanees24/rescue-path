import SwiftUI

/// The FIREFIGHTER side: one tactical radar screen that finds and tracks the beacon phone,
/// like Find My's Precision Finding. Real NI data only.
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
            tacText("PHONE ON CHEST · SCREEN FACING YOU · BACK FACING FORWARD", 9)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.bottom, 2)
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
                tacText(stateLine, 11, .bold).foregroundStyle(phaseColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 10) {
                    pip("W", store.boards.isReady(.waist))
                    pip("L", store.boards.isReady(.left))
                    pip("R", store.boards.isReady(.right))
                    pip("U", store.uwbLinked)
                }
                tacText("UWB · \(Int(store.scopeRange))M", 11).foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 12)
    }

    private var stateLine: String {
        switch store.phase {
        case .searchingRanged:
            return store.distance.map { String(format: "SEARCHING · %.1f M", $0) } ?? "SEARCHING"
        case .far:
            return store.distance.map { String(format: "FAR · BLE · ~%.0f M", $0) } ?? "FAR · BLE"
        default:
            return store.phase.label
        }
    }

    private var phaseColor: Color {
        switch store.phase {
        case .tracking, .onTarget: Theme.teal
        case .gyro, .searchingRanged, .far: Theme.ink
        case .searching, .outOfRange: Theme.dim
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
                track: store.track,
                hasFix: store.hasFix,
                directionLive: store.directionLive,
                phase: store.phase,
                aligned: aligned,
                farDistance: store.phase == .far ? store.distance : nil,
                obstacleCm: store.obstacleCm,
                obstacleVisibility: store.obstacleVisibility,
                halfAngle: RadarStore.halfAngle,
                maxRange: store.displayRange,
                labelRange: store.scopeRange)
            let date = tl.date
            Canvas { ctx, size in
                ScopeRenderer(s: snap, now: date, size: size).draw(ctx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// Facing the target: |bearing| ≤ 15° with live direction.
    private var aligned: Bool {
        guard store.phase == .tracking, let r = store.relativeBearing else { return false }
        return abs(r) <= 15
    }

    private var accessibilitySummary: String {
        guard let d = store.countedDistance else { return "\(store.phase.label.capitalized)." }
        return String(format: "Beacon %.1f metres, %@. Bracelets: %@.", d, directionLine, cueText)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if store.isOnTarget, let d = store.countedDistance {
            centeredFooter(String(format: "ON TARGET · %.1f M", d), color: Theme.teal, glow: true)
        } else if store.countedDistance == nil {
            centeredFooter(store.phase == .outOfRange ? "OUT OF RANGE" : "SEARCHING", color: Theme.ink, glow: false)
        } else {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(distanceText)
                        .font(.system(size: 44, weight: .medium, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(store.phase == .tracking ? Theme.ink : Theme.dim)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    tacText(directionLine, 12, .bold)
                        .foregroundStyle(aligned ? Theme.teal : (store.hasFix ? Theme.ink : Theme.dim))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    cueLabel
                    rxLabel
                }
                .layoutPriority(1)
            }
            .padding(.vertical, 12)
        }
    }

    private var distanceText: String {
        guard let d = store.countedDistance else { return "--" }
        return store.phase == .far ? String(format: "~%.0f M", d) : String(format: "%.1f M", d)
    }

    private func centeredFooter(_ text: String, color: Color, glow: Bool) -> some View {
        VStack(spacing: 8) {
            tacText(text, 20, .bold)
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

    /// The cue actually being sent to the bracelets.
    private var cueLabel: some View {
        let cue = store.guidance.cue
        let color: Color = cue == .stop && store.guidance.hapticsEnabled ? (store.isOnTarget ? Theme.teal : Theme.red)
            : (store.guidance.detourSide != nil ? Theme.red : Theme.ink)
        return tacText(cueText, 14, .bold).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
    }

    /// Exactly what's being sent to the bracelets.
    private var cueText: String { store.guidance.sentLabel }

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

    /// Find My wording.
    private var directionLine: String {
        guard store.hasFix, let r = store.relativeBearing else { return "TURN SLOWLY" }
        return Self.directionWords(r)
    }

    static func directionWords(_ r: Double) -> String {
        switch abs(r) {
        case ...20: return "AHEAD"
        case ...135: return r < 0 ? "TO YOUR LEFT" : "TO YOUR RIGHT"
        default: return "BEHIND YOU"
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            Button {
                store.restartScan()
            } label: {
                TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                    let blink = store.phase == .searching
                    let on = !blink || tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.6
                    tacText("[SCAN]", 13, .bold)
                        .foregroundStyle(Theme.ping)
                        .opacity(on ? 1 : 0.35)
                }
                .frame(minWidth: 72, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Restart the search for the beacon")

            Spacer()

            Button {
                store.guidance.hapticsEnabled.toggle()
            } label: {
                tacText(store.guidance.hapticsEnabled ? "[HAPTICS ON]" : "[HAPTICS OFF]", 13, .bold)
                    .foregroundStyle(store.guidance.hapticsEnabled ? Theme.teal : Theme.line)
                    .lineLimit(1)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(store.guidance.hapticsEnabled ? "Haptics on. Tap to turn off." : "Haptics off. Tap to turn on.")

            Spacer()

            Button {
                showLog = true
            } label: {
                tacText("[LOG]", 13, .bold)
                    .foregroundStyle(Theme.line)
                    .frame(minWidth: 72, minHeight: 44, alignment: .trailing)
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
    let track: TrackSnapshot
    let hasFix: Bool
    /// A valid UWB direction in the last 0.6 s (else running on the gyro latch).
    let directionLive: Bool
    let phase: ScanPhase
    let aligned: Bool
    /// FAR · BLE: rough RSSI distance (m).
    let farDistance: Double?
    let obstacleCm: Double
    let obstacleVisibility: Double
    let halfAngle: Double
    /// Eased scope range (m) used for scaling, so the dot and trail rescale smoothly.
    let maxRange: Double
    /// Current range step (5/10/20/40 m) used for the ring labels.
    let labelRange: Double
}

/// Heading-up polar scope: me at the bottom centre, up = where the phone's back points.
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

    /// Dimmed when not running on a live UWB direction.
    private var targetAlpha: Double {
        switch s.phase {
        case .tracking: 1.0
        case .onTarget: s.directionLive ? 1.0 : 0.65
        case .gyro: 0.65
        case .far: 0.45
        case .outOfRange, .searching, .searchingRanged: 0.35
        }
    }

    func draw(_ ctx: GraphicsContext) {
        if s.aligned { ctx.fill(wedge(), with: .color(Theme.teal.opacity(0.05))) }
        drawGrid(ctx)
        if s.phase != .outOfRange { drawPing(ctx) }
        drawNoise(ctx)
        drawObstacle(ctx)
        drawFarRing(ctx)
        drawTarget(ctx)
        drawOrigin(ctx)
        drawStateLabel(ctx)
    }

    // MARK: Grid

    private func drawGrid(_ ctx: GraphicsContext) {
        let h = s.halfAngle
        var radials = Path()
        for i in 0..<5 where i != 2 {
            let a = -h + 2 * h * Double(i) / 4
            radials.move(to: origin)
            radials.addLine(to: pointPx(a, radius))
        }
        var rings = Path()
        for k in 1...5 { rings.addPath(arcPoints(radius * CGFloat(k) / 5)) }
        ctx.stroke(radials, with: .color(Theme.grid), lineWidth: 1)
        ctx.stroke(rings, with: .color(Theme.grid.opacity(0.75)), lineWidth: 1)

        // Centre line: brightens teal when you're facing the target.
        var centre = Path()
        centre.move(to: origin)
        centre.addLine(to: pointPx(0, radius))
        if s.aligned {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 3))
                layer.stroke(centre, with: .color(Theme.teal.opacity(0.8)), lineWidth: 3)
            }
            ctx.stroke(centre, with: .color(Theme.teal), lineWidth: 1.5)
        } else {
            ctx.stroke(centre, with: .color(Theme.grid), lineWidth: 1)
        }

        // Ring labels on the centre line: 1–5 m, 2–10 m, 4–20 m or 8–40 m.
        for k in 1...5 {
            let meters = Int((s.labelRange / 5 * Double(k)).rounded())
            ctx.draw(Text("\(meters)M")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Theme.dim),
                     at: CGPoint(x: origin.x + 5, y: origin.y - radius * CGFloat(k) / 5 - 7), anchor: .leading)
        }
    }

    /// Two tiny fixed specks of screen grain (static, decorative).
    private func drawNoise(_ ctx: GraphicsContext) {
        for (a, f) in [(-27.0, 0.72), (19.0, 0.36)] {
            let p = pointPx(a, radius * CGFloat(f))
            ctx.fill(Path(CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)), with: .color(Theme.ink.opacity(0.35)))
        }
    }

    /// With nothing to draw yet, say so in the scope.
    private func drawStateLabel(_ ctx: GraphicsContext) {
        let text: String
        switch s.phase {
        case .searching where s.track.position == nil: text = "SEARCHING"
        case .outOfRange: text = "OUT OF RANGE"
        default: return
        }
        ctx.draw(Text(text)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(Theme.ink.opacity(0.6)),
                 at: pointPx(0, radius * 0.62))
    }

    // MARK: Ping

    /// A band of 5 thin light-blue arcs, 6 pt apart, expanding from the origin in ~0.6 s
    /// (ease-out), relaunching every ~0.75 s. Searching: 1.5 s cycle, dim. On target: teal.
    private func drawPing(_ ctx: GraphicsContext) {
        let searching = s.phase == .searching || s.phase == .searchingRanged || s.phase == .far
        let cycle = searching ? 1.5 : 0.75
        let launch = searching ? 1.2 : 0.6
        let e = time.truncatingRemainder(dividingBy: cycle)
        guard e < launch else { return }
        let u = e / launch
        let eased = 1 - pow(1 - u, 3)
        let lead = CGFloat(eased) * radius
        let color = s.phase == .onTarget ? Theme.teal : Theme.ping
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

    // MARK: Obstacle

    private func drawObstacle(_ ctx: GraphicsContext) {
        guard s.obstacleVisibility > 0.02 else { return }
        // Short red arc straight ahead at the ultrasonic distance (shown under 1.5 m).
        let meters = min(s.obstacleCm / 100, s.maxRange)
        let color = Theme.red
        let a = s.obstacleVisibility
        // Readable at any scope range: at least 28 pt out and about 36 pt long.
        let r = max(28, CGFloat(meters) * ppm)
        let half = max(12, Double(18 / r) * 180 / .pi)
        let bar = arcPoints(r, from: -half, to: half)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(bar, with: .color(color.opacity(a * 0.7)), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
        }
        ctx.stroke(bar, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
        ctx.draw(Text("\(Int(s.obstacleCm.rounded()))CM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(color.opacity(a)),
                 at: pointPx(half + 2, r), anchor: .leading)
    }

    // MARK: FAR · BLE

    /// Rough RSSI distance: a wide dashed ring with "~15 M".
    private func drawFarRing(_ ctx: GraphicsContext) {
        guard let d = s.farDistance else { return }
        let r = CGFloat(min(d, s.maxRange)) * ppm
        ctx.stroke(arcPoints(r), with: .color(Theme.ink.opacity(0.28)),
                   style: StrokeStyle(lineWidth: 10, lineCap: .butt, dash: [6, 8]))
        ctx.draw(Text(String(format: "~%.0f M", d))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.ink.opacity(0.7)),
                 at: pointPx(-s.halfAngle + 6, r + 14), anchor: .leading)
    }

    // MARK: Target 01 (real NI data only)

    private func drawTarget(_ ctx: GraphicsContext) {
        let t = s.track
        guard s.hasFix, let pos = t.position else {
            // Distance known, direction not yet latched: dashed ring at that range, no arrow.
            if s.phase == .searchingRanged, let d = t.distance {
                ctx.stroke(arcPoints(CGFloat(min(d, s.maxRange)) * ppm), with: .color(Theme.ink.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            return
        }
        let a = targetAlpha
        let rel = Compass.delta(Compass.bearing(from: s.origin, to: pos), s.heading)
        // FAR: keep the last known bearing, at the rough RSSI distance.
        let d = s.farDistance ?? s.origin.distance(to: pos)
        // Live UWB direction: solid arrow. Gyro latch / far / out of range: dashed, dimmed.
        let dashed = s.farDistance != nil || !s.directionLive || s.phase == .outOfRange

        if s.farDistance == nil { drawTrail(ctx, alpha: a) }
        let p = point(rel, min(d, s.maxRange))
        if abs(rel) <= s.halfAngle {
            drawArrow(ctx, to: p, alpha: a, dashed: dashed)
        } else {
            drawTurnArrow(ctx, toward: rel, alpha: a, dashed: dashed)
        }
        if contains(p) {
            drawMarker(ctx, at: p, alpha: a, label: "01")
        }
    }

    /// 2 pt teal line from the origin to just short of the dot, with a chevron head and glow.
    private func drawArrow(_ ctx: GraphicsContext, to p: CGPoint, alpha a: Double, dashed: Bool) {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let len = hypot(dx, dy)
        guard len > 26 else { return }              // too close to draw a meaningful arrow
        let ux = dx / len, uy = dy / len
        let start = CGPoint(x: origin.x + ux * 10, y: origin.y + uy * 10)
        let tip = CGPoint(x: p.x - ux * 11, y: p.y - uy * 11)       // just short of the 14 pt dot
        strokeArrow(ctx, from: start, tip: tip, ux: ux, uy: uy, head: 7, alpha: a, dashed: dashed)
    }

    /// Target outside the wedge: line to the wedge edge, larger chevron on the edge pointing
    /// the way to turn, and "TURN LEFT" / "TURN RIGHT" beside it.
    private func drawTurnArrow(_ ctx: GraphicsContext, toward rel: Double, alpha a: Double, dashed: Bool) {
        let left = rel < 0
        let edge = left ? -s.halfAngle : s.halfAngle
        let along = Compass.unit(edge)
        let c = pointPx(edge, radius * 0.55)
        let start = CGPoint(x: origin.x + along.dx * 10, y: origin.y + along.dy * 10)
        let lineEnd = CGPoint(x: c.x - along.dx * 4, y: c.y - along.dy * 4)
        var line = Path()
        line.move(to: start)
        line.addLine(to: lineEnd)
        let color = Theme.teal.opacity(a)
        let style = StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [6, 5] : [])
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: style.dash))
        }
        ctx.stroke(line, with: .color(color), style: style)

        // Larger chevron on the edge, pointing outward (the turning direction).
        let out = Compass.unit(edge + (left ? -90 : 90))
        let back = Compass.unit(edge + (left ? 90 : -90))
        let tip = CGPoint(x: c.x + out.dx * 14, y: c.y + out.dy * 14)
        let w1 = CGPoint(x: c.x + back.dx * 4 + along.dx * 16, y: c.y + back.dy * 4 + along.dy * 16)
        let w2 = CGPoint(x: c.x + back.dx * 4 - along.dx * 16, y: c.y + back.dy * 4 - along.dy * 16)
        var chev = Path()
        chev.move(to: w1)
        chev.addLine(to: tip)
        chev.addLine(to: w2)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(chev, with: .color(color), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(chev, with: .color(color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

        // Label above the chevron, clamped inside the scope so it never runs off-screen.
        let turn = ctx.resolve(Text(left ? "TURN LEFT" : "TURN RIGHT")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(color))
        let deg = ctx.resolve(Text("\(Int(abs(rel).rounded()))°")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(color.opacity(0.8)))
        let tw = turn.measure(in: size).width
        let cx = min(max(c.x, tw / 2 + 4), size.width - tw / 2 - 4)
        let cy = max(16, c.y - 42)
        ctx.draw(turn, at: CGPoint(x: cx, y: cy), anchor: .center)
        ctx.draw(deg, at: CGPoint(x: cx, y: cy + 14), anchor: .center)
    }

    private func strokeArrow(_ ctx: GraphicsContext, from start: CGPoint, tip: CGPoint, ux: CGFloat, uy: CGFloat,
                             head: CGFloat, alpha a: Double, dashed: Bool) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: tip)
        // Chevron head: two short strokes swept back from the tip.
        let px = -uy, py = ux
        var chev = Path()
        chev.move(to: CGPoint(x: tip.x - ux * head + px * head * 0.8, y: tip.y - uy * head + py * head * 0.8))
        chev.addLine(to: tip)
        chev.addLine(to: CGPoint(x: tip.x - ux * head - px * head * 0.8, y: tip.y - uy * head - py * head * 0.8))
        let color = Theme.teal.opacity(a)
        let dash: [CGFloat] = dashed ? [6, 5] : []
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dash))
            layer.stroke(chev, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
        ctx.stroke(chev, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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

        // Keep the label clear of the origin marker at very close range.
        let nearOrigin = hypot(p.x - origin.x, p.y - origin.y) < 30
        let onLeft = p.x > size.width - 120
        let dy: CGFloat = nearOrigin ? -14 : 0
        ctx.draw(Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.teal.opacity(max(a, 0.6))),
                 at: CGPoint(x: onLeft ? p.x - 15 : p.x + 15, y: p.y + dy),
                 anchor: onLeft ? .trailing : .leading)
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

    /// Point at a relative bearing and a distance in meters (scaled by the eased range).
    private func point(_ relBearing: Double, _ meters: Double) -> CGPoint {
        pointPx(relBearing, CGFloat(meters) * ppm)
    }

    private func pointPx(_ relBearing: Double, _ r: CGFloat) -> CGPoint {
        let u = Compass.unit(relBearing)
        return CGPoint(x: origin.x + u.dx * r, y: origin.y + u.dy * r)
    }

    private func screenPoint(world w: CGPoint) -> CGPoint? {
        let d = s.origin.distance(to: w)
        guard d <= s.maxRange * 1.1 else { return nil }
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
        p.addPath(arcPoints(radius))
        p.addLine(to: origin)
        p.closeSubpath()
        return p
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
