import SwiftUI

/// World (meters) ↔ screen (points), fitting the plan's view bounds into the canvas.
struct MapTransform {
    let bounds: CGRect
    let scale: CGFloat
    let origin: CGPoint

    init(bounds: CGRect, size: CGSize) {
        self.bounds = bounds
        let s = max(0.001, min(size.width / bounds.width, size.height / bounds.height))
        scale = s
        origin = CGPoint(x: (size.width - bounds.width * s) / 2,
                         y: (size.height - bounds.height * s) / 2)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (p.x - bounds.minX) * scale, y: origin.y + (p.y - bounds.minY) * scale)
    }

    func toScreen(_ r: CGRect) -> CGRect {
        let o = toScreen(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale + bounds.minX, y: (p.y - origin.y) / scale + bounds.minY)
    }

    func length(_ meters: Double) -> CGFloat { CGFloat(meters) * scale }
}

/// Plain values copied out of the store for one frame of drawing.
struct RadarSnapshot {
    let plan: FloorPlan
    let firefighter: CGPoint
    let heading: Double
    let target: TargetDisplay
    let providesBearing: Bool
    let blips: [Blip]
    let truth: [SimPerson]
    let showTruth: Bool
    let range: Double
    let halfAngle: Double
}

struct RadarMapView: View {
    let store: RadarStore
    @State private var rotateBase: Double?

    var body: some View {
        GeometryReader { geo in
            let xf = MapTransform(bounds: store.plan.viewBounds, size: geo.size)
            ZStack(alignment: .top) {
                TimelineView(.animation) { timeline in
                    let snap = snapshot()
                    let date = timeline.date
                    Canvas { ctx, size in
                        RadarRenderer(s: snap, xf: xf, now: date, size: size).draw(ctx)
                    }
                }
                firefighterHandle(xf)
                if store.scanning {
                    scanBanner.padding(.top, 8)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named("map"))
            .contentShape(Rectangle())
            .gesture(rotateGesture)
        }
        .clipped()
    }

    private func snapshot() -> RadarSnapshot {
        RadarSnapshot(plan: store.plan, firefighter: store.firefighter, heading: store.displayHeading,
                      target: store.target, providesBearing: store.providesBearing, blips: store.blips,
                      truth: store.sourceKind == .sim ? store.simTruth : [],
                      showTruth: store.showTruth && store.sourceKind == .sim,
                      range: RadarStore.range, halfAngle: RadarStore.halfAngle)
    }

    /// Invisible, glove-sized touch target on top of the drawn marker.
    private func firefighterHandle(_ xf: MapTransform) -> some View {
        Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 88, height: 88)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("map"))
                    .onChanged { v in store.moveFirefighter(to: xf.toWorld(v.location)) }
            )
            .position(xf.toScreen(store.firefighter))
            .accessibilityLabel("Firefighter position. Drag to move.")
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { v in
                if rotateBase == nil {
                    store.setUseCompass(false)
                    rotateBase = store.manualHeading
                }
                store.manualHeading = Compass.normalize((rotateBase ?? 0) + v.rotation.degrees)
            }
            .onEnded { _ in rotateBase = nil }
    }

    private var scanBanner: some View {
        Text("● SCANNING — TURN SLOWLY IN PLACE")
            .font(Theme.mono(13, .heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.cyan, in: Capsule())
            .allowsHitTesting(false)
    }
}

/// Draws one frame: floor plan, scan blips, radar cone + sweep, target, firefighter.
struct RadarRenderer {
    let s: RadarSnapshot
    let xf: MapTransform
    let now: Date
    let size: CGSize

    private var time: Double { now.timeIntervalSinceReferenceDate }
    private var center: CGPoint { xf.toScreen(s.firefighter) }
    private var lo: Double { s.heading - s.halfAngle }
    private var hi: Double { s.heading + s.halfAngle }

    func draw(_ ctx: GraphicsContext) {
        drawGrid(ctx)
        drawRooms(ctx)
        drawWalls(ctx)
        if s.showTruth { drawTruth(ctx) }
        drawBlips(ctx)
        drawCone(ctx)
        drawSweep(ctx)
        drawTarget(ctx)
        drawFirefighter(ctx)
    }

    // MARK: Floor plan

    private func drawGrid(_ ctx: GraphicsContext) {
        let b = s.plan.viewBounds
        var p = Path()
        var x = b.minX.rounded(.up)
        while x <= b.maxX {
            p.move(to: xf.toScreen(CGPoint(x: x, y: b.minY)))
            p.addLine(to: xf.toScreen(CGPoint(x: x, y: b.maxY)))
            x += 1
        }
        var y = b.minY.rounded(.up)
        while y <= b.maxY {
            p.move(to: xf.toScreen(CGPoint(x: b.minX, y: y)))
            p.addLine(to: xf.toScreen(CGPoint(x: b.maxX, y: y)))
            y += 1
        }
        ctx.stroke(p, with: .color(Theme.grid), lineWidth: 1)
    }

    private func drawRooms(_ ctx: GraphicsContext) {
        for room in s.plan.rooms {
            let r = xf.toScreen(room.rect)
            ctx.fill(Path(r), with: .color(Theme.roomFill))
            ctx.draw(Text(room.name.uppercased())
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(Theme.dim),
                     at: CGPoint(x: r.midX, y: r.minY + 14))
        }
    }

    private func drawWalls(_ ctx: GraphicsContext) {
        var p = Path()
        for w in s.plan.walls {
            p.move(to: xf.toScreen(w.a))
            p.addLine(to: xf.toScreen(w.b))
        }
        ctx.stroke(p, with: .color(Theme.wall),
                   style: StrokeStyle(lineWidth: max(3, xf.length(0.15)), lineCap: .round))
    }

    private func drawTruth(_ ctx: GraphicsContext) {
        for person in s.truth {
            let c = xf.toScreen(person.position)
            let rect = CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            ctx.draw(Text("SIM").font(Theme.mono(9, .bold)).foregroundStyle(Color.white.opacity(0.55)),
                     at: CGPoint(x: c.x, y: c.y + 16))
        }
    }

    // MARK: Scan blips

    private func drawBlips(_ ctx: GraphicsContext) {
        guard !s.blips.isEmpty else { return }
        let r = max(5, xf.length(0.18))
        func alpha(_ b: Blip) -> Double {
            max(0, 1 - now.timeIntervalSince(b.time) / RadarStore.blipLifetime)
        }
        func dot(_ b: Blip, _ radius: CGFloat) -> Path {
            let c = xf.toScreen(b.position)
            return Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            for b in s.blips {
                layer.fill(dot(b, r * 1.8), with: .color(Theme.cyan.opacity(0.7 * alpha(b))))
            }
        }
        for b in s.blips {
            ctx.fill(dot(b, r), with: .color(Theme.cyan.opacity(alpha(b))))
        }
    }

    // MARK: Cone and sweep

    private func drawCone(_ ctx: GraphicsContext) {
        let c = center
        let R = xf.length(s.range)
        let wedge = wedgePath(c, R, lo, hi)
        ctx.fill(wedge, with: .radialGradient(
            Gradient(colors: [Theme.radar.opacity(0.26), Theme.radar.opacity(0.05)]),
            center: c, startRadius: 0, endRadius: R))

        var rings = Path()
        for m in 1...Int(s.range) {
            rings.addPath(arcPath(c, xf.length(Double(m)), lo, hi))
        }
        ctx.stroke(rings, with: .color(Theme.radar.opacity(0.35)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        ctx.stroke(wedge, with: .color(Theme.radar.opacity(0.75)), lineWidth: 1.5)

        for m in 1...Int(s.range) {
            let p = point(c, xf.length(Double(m)), lo - 4)
            ctx.draw(Text("\(m)m").font(Theme.mono(10, .bold)).foregroundStyle(Theme.radar.opacity(0.8)), at: p)
        }
    }

    private func drawSweep(_ ctx: GraphicsContext) {
        let c = center
        let R = xf.length(s.range)
        let period = 2.4
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let tri = phase < 0.5 ? phase * 2 : 2 - phase * 2       // ping-pong across the cone
        let dir: Double = phase < 0.5 ? 1 : -1
        let a = lo + (hi - lo) * tri

        let slices = 12
        let sliceWidth = 2.5
        for i in 0..<slices {
            let a1 = a - dir * Double(i) * sliceWidth
            let a0 = a1 - dir * sliceWidth
            let start = max(lo, min(a0, a1))
            let end = min(hi, max(a0, a1))
            guard end - start > 0.1 else { continue }
            let opacity = 0.22 * (1 - Double(i) / Double(slices))
            ctx.fill(wedgePath(c, R, start, end), with: .color(Theme.radar.opacity(opacity)))
        }
        var line = Path()
        line.move(to: c)
        line.addLine(to: point(c, R, a))
        ctx.stroke(line, with: .color(Theme.radar.opacity(0.9)), lineWidth: 2)
    }

    // MARK: Target

    /// A dot where the target is when there's a bearing; a range band across the cone
    /// when there isn't (radar, or UWB direction lost).
    private func drawTarget(_ ctx: GraphicsContext) {
        let t = s.target
        guard t.visibility > 0.02 else { return }
        let c = center
        let r = xf.length(min(max(t.distance, 0.2), s.range))
        let ringAlpha = s.providesBearing ? t.visibility * (1 - t.bearingVisibility) : t.visibility
        if ringAlpha > 0.02 {
            let arc = arcPath(c, r, lo, hi)
            let width = max(8, xf.length(0.3))
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 8))
                layer.stroke(arc, with: .color(Theme.cyan.opacity(ringAlpha)),
                             style: StrokeStyle(lineWidth: width * 2, lineCap: .round))
            }
            ctx.stroke(arc, with: .color(Theme.cyan.opacity(0.8 * ringAlpha)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        let dotAlpha = s.providesBearing ? t.visibility * t.bearingVisibility : 0
        if dotAlpha > 0.02 {
            let p = point(c, xf.length(t.distance), s.heading + t.bearing)
            let dot = Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                layer.fill(dot, with: .color(Theme.cyan.opacity(dotAlpha)))
            }
            ctx.stroke(dot, with: .color(Theme.cyan.opacity(dotAlpha)), lineWidth: 2)
        }
        drawLabel(ctx, String(format: "TARGET %.1f m", t.distance),
                  at: point(c, r + 24, s.heading), color: Theme.cyan, alpha: t.visibility)
    }

    private func drawLabel(_ ctx: GraphicsContext, _ text: String, at p: CGPoint, color: Color, alpha: Double) {
        let resolved = ctx.resolve(Text(text).font(Theme.mono(13, .heavy)).foregroundStyle(Color.white))
        let sz = resolved.measure(in: CGSize(width: size.width, height: 100))
        let w = sz.width + 16
        let h = sz.height + 8
        let x = min(max(p.x, w / 2 + 4), size.width - w / 2 - 4)
        let y = min(max(p.y, h / 2 + 4), size.height - h / 2 - 4)
        let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
        var c = ctx
        c.opacity = alpha
        let box = Path(roundedRect: rect, cornerRadius: 8)
        c.fill(box, with: .color(Color.black.opacity(0.82)))
        c.stroke(box, with: .color(color), lineWidth: 2)
        c.draw(resolved, at: CGPoint(x: x, y: y))
    }

    // MARK: Firefighter

    private func drawFirefighter(_ ctx: GraphicsContext) {
        let c = center
        var arrow = Path()
        arrow.move(to: point(c, 30, s.heading))
        arrow.addLine(to: point(c, 13, s.heading - 50))
        arrow.addLine(to: point(c, 13, s.heading + 50))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(Theme.firefighter))

        let dot = Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
        ctx.fill(dot, with: .color(Theme.firefighter))
        ctx.stroke(dot, with: .color(.white), lineWidth: 3)
        ctx.draw(Text("YOU").font(Theme.mono(11, .heavy)).foregroundStyle(Color.white),
                 at: point(c, 28, s.heading + 180))
    }

    // MARK: Geometry helpers (bearing-based, so no arc-direction surprises)

    private func point(_ c: CGPoint, _ r: CGFloat, _ bearing: Double) -> CGPoint {
        let u = Compass.unit(bearing)
        return CGPoint(x: c.x + u.dx * r, y: c.y + u.dy * r)
    }

    private func arcPath(_ c: CGPoint, _ r: CGFloat, _ b0: Double, _ b1: Double) -> Path {
        var p = Path()
        let steps = max(2, Int((b1 - b0) / 2))
        for i in 0...steps {
            let pt = point(c, r, b0 + (b1 - b0) * Double(i) / Double(steps))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func wedgePath(_ c: CGPoint, _ r: CGFloat, _ b0: Double, _ b1: Double) -> Path {
        var p = Path()
        p.move(to: c)
        let steps = max(2, Int((b1 - b0) / 2))
        for i in 0...steps {
            p.addLine(to: point(c, r, b0 + (b1 - b0) * Double(i) / Double(steps)))
        }
        p.closeSubpath()
        return p
    }
}
