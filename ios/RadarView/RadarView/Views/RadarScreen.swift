import SwiftUI

/// Main screen: a minimal, heading-up tactical handheld radar.
struct RadarScreen: View {
    let store: RadarStore
    @State private var showMap = false
    @State private var rotateBase: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            wedge
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
        .fullScreenCover(isPresented: $showMap) {
            MapScreen(store: store)
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            store.setMode(store.mode == .simulated ? .live : .simulated)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    tacText("FF-RADAR", 14, .bold).foregroundStyle(Theme.ink)
                    tacText(subtitle, 11).foregroundStyle(Theme.dim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                        let live = store.mode == .live
                        let on = !live || tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) < 1.3
                        tacText(live ? "LIVE" : "SIM", 14, .bold)
                            .foregroundStyle(live ? Theme.cyan : Theme.ink)
                            .opacity(on ? 1 : 0.2)
                            .glow(live ? Theme.cyan : .clear, radius: 3)
                    }
                    tacText("6M", 11).foregroundStyle(Theme.dim)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Data source \(store.mode == .live ? "live" : "simulated")")
        .accessibilityHint("Switches between simulated and live radar data")
    }

    private var subtitle: String {
        guard store.mode == .live else { return "SEARCH MODE" }
        switch store.ble.state {
        case .connected: return "SEARCH MODE"
        case .scanning: return "LINK SEARCH"
        case .connecting: return "LINKING"
        case .reconnecting: return "RELINKING"
        case .poweredOff: return "BT OFF"
        case .unauthorized: return "BT DENIED"
        case .unsupported: return "NO BT"
        case .idle: return "LINK IDLE"
        }
    }

    // MARK: Wedge

    private var wedge: some View {
        TimelineView(.animation) { tl in
            let snap = TacticalSnapshot(
                heading: store.displayHeading,
                firefighter: store.firefighter,
                moving: store.moving,
                still: store.still,
                movingTrail: store.trails[.moving] ?? [],
                stillTrail: store.trails[.still] ?? [],
                blips: store.blips,
                halfAngle: RadarStore.halfAngle,
                range: RadarStore.range)
            let date = tl.date
            Canvas { ctx, size in
                TacticalRenderer(s: snap, now: date, size: size).draw(ctx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(rotateGesture)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// Two-finger twist sets heading by hand (fallback when there's no compass).
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

    private var accessibilitySummary: String {
        switch store.priorityKind {
        case .still: return "Still person \(String(format: "%.1f", store.still.distance)) metres ahead. Check."
        case .moving: return "Moving person \(String(format: "%.1f", store.moving.distance)) metres ahead."
        case nil: return "No contact."
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                tacText("TGT \(store.targetCount)", 12, .bold).foregroundStyle(Theme.ink)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            distanceReadout
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 5) {
                tacText("6m", 12, .bold).foregroundStyle(Theme.ink)
                tacText(store.updateRate > 0 ? "RX \(Int(store.updateRate.rounded()))Hz" : "RX --", 11)
                    .foregroundStyle(store.updateRate > 0 ? Theme.line : Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var status: some View {
        switch store.priorityKind {
        case .still:
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                let on = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.6
                tacText("STILL — CHECK", 11, .bold)
                    .foregroundStyle(Theme.red)
                    .opacity(on ? 1 : 0.25)
                    .glow(Theme.red, radius: 3)
            }
        case .moving:
            tacText("TRACKING", 11, .bold).foregroundStyle(Theme.cyan).glow(Theme.cyan, radius: 3)
        case nil:
            tacText("NO CONTACT", 11).foregroundStyle(Theme.dim)
        }
    }

    private var distanceReadout: some View {
        let kind = store.priorityKind
        let color: Color = kind == .still ? Theme.red : (kind == .moving ? Theme.cyan : Theme.dim)
        let text = kind.map { String(format: "%.1fm", store.track($0).distance) } ?? "--"
        return Text(text)
            .font(.system(size: 34, weight: .medium, design: .monospaced))
            .tracking(2)
            .foregroundStyle(color)
            .glow(kind == nil ? .clear : color, radius: 4)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            Button {
                store.scanning.toggle()
            } label: {
                tacText(store.scanning ? "[SCAN ●]" : "[SCAN]", 13, .bold)
                    .foregroundStyle(store.scanning ? Theme.cyan : Theme.line)
                    .glow(store.scanning ? Theme.cyan : .clear, radius: 3)
                    .frame(minWidth: 96, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(store.scanning ? "Stop scan" : "Start scan")

            Spacer()

            Button {
                showMap = true
            } label: {
                tacText("[MAP]", 13, .bold)
                    .foregroundStyle(Theme.line)
                    .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open floor plan and alert log")
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

// MARK: - Drawing

struct TacticalSnapshot {
    let heading: Double
    let firefighter: CGPoint
    let moving: TrackDisplay
    let still: TrackDisplay
    let movingTrail: [Double]
    let stillTrail: [Double]
    let blips: [Blip]
    let halfAngle: Double
    let range: Double
}

/// Heading-up wedge: up is always where the phone points. The LD2410B has no angle,
/// so targets sit on the centre line at the reported distance.
struct TacticalRenderer {
    let s: TacticalSnapshot
    let now: Date
    let size: CGSize

    private var time: Double { now.timeIntervalSinceReferenceDate }

    /// Wedge radius in points, as large as fits the width and height.
    private var radius: CGFloat {
        let byWidth = (size.width / 2 - 4) / CGFloat(sin(s.halfAngle * .pi / 180))
        let byHeight = size.height - 40
        return max(40, min(byWidth, byHeight))
    }

    /// Wedge apex: bottom centre, with the wedge vertically centred in the space.
    private var origin: CGPoint {
        CGPoint(x: size.width / 2, y: min(size.height - 16, size.height / 2 + radius / 2 + 8))
    }

    private var ppm: CGFloat { radius / CGFloat(s.range) }

    func draw(_ ctx: GraphicsContext) {
        drawGrid(ctx)
        drawNoise(ctx)
        drawBlips(ctx)
        drawPing(ctx, s.moving, Theme.cyan)
        drawPing(ctx, s.still, Theme.red)
        drawTrail(ctx, s.movingTrail, s.moving, Theme.cyan)
        drawTrail(ctx, s.stillTrail, s.still, Theme.red)
        drawMarkers(ctx)
        drawApex(ctx)
    }

    // MARK: Grid

    private func drawGrid(_ ctx: GraphicsContext) {
        let h = s.halfAngle
        var inner = Path()
        var outer = Path()
        for i in 0..<5 {
            let a = -h + 2 * h * Double(i) / 4
            var p = Path()
            p.move(to: origin)
            p.addLine(to: point(a, s.range))
            if i == 0 || i == 4 { outer.addPath(p) } else { inner.addPath(p) }
        }
        outer.addPath(arc(s.range))
        var rings = Path()
        for m in [1.5, 3.0, 4.5] { rings.addPath(arc(m)) }

        ctx.stroke(inner, with: .color(Theme.ink.opacity(0.2)), lineWidth: 1)
        ctx.stroke(rings, with: .color(Theme.ink.opacity(0.28)), lineWidth: 1)
        ctx.stroke(outer, with: .color(Theme.line), lineWidth: 1)

        for m in [1.5, 3.0, 4.5, 6.0] {
            let y = origin.y - CGFloat(m) * ppm - 7
            ctx.draw(Text(String(format: "%.1fm", m))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Theme.dim),
                     at: CGPoint(x: origin.x + 5, y: y), anchor: .leading)
        }
    }

    /// Faint flickering static inside the wedge.
    private func drawNoise(_ ctx: GraphicsContext) {
        let bucket = UInt64(max(0, time / 0.12))
        for i in 0..<16 {
            var h = mix(bucket &* 1_000_003 &+ UInt64(i))
            let u = Double(h & 0xFFFF) / 65535
            h = mix(h)
            let v = Double(h & 0xFFFF) / 65535
            h = mix(h)
            let a = Double(h & 0xFFFF) / 65535
            let p = point(-s.halfAngle + 2 * s.halfAngle * u, 0.4 + (s.range - 0.4) * sqrt(v))
            ctx.fill(Path(CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)),
                     with: .color(Theme.ink.opacity(0.08 + 0.32 * a)))
        }
    }

    // MARK: Scan blips (world-fixed, rotate as you turn)

    private func drawBlips(_ ctx: GraphicsContext) {
        guard !s.blips.isEmpty else { return }
        for b in s.blips {
            let d = s.firefighter.distance(to: b.position)
            guard d <= s.range + 0.5 else { continue }
            let rel = Compass.delta(Compass.bearing(from: s.firefighter, to: b.position), s.heading)
            let p = point(rel, d)
            guard p.x >= 0, p.x <= size.width, p.y >= 0, p.y <= size.height else { continue }
            let alpha = max(0, 1 - now.timeIntervalSince(b.time) / RadarStore.blipLifetime)
            ctx.fill(Path(CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                     with: .color(Theme.color(for: b.kind).opacity(alpha)))
        }
    }

    // MARK: Ping band

    /// 4 stacked thin arcs at the target's distance, fading outward and drifting slowly.
    private func drawPing(_ ctx: GraphicsContext, _ t: TrackDisplay, _ color: Color) {
        guard t.visibility > 0.02 else { return }
        let step = Double(5 / ppm)
        let drift = (time * 0.8).truncatingRemainder(dividingBy: 1)
        var arcs: [(Path, Double)] = []
        for i in 0..<4 {
            let k = Double(i) + drift
            let m = t.distance + k * step
            guard m <= s.range + 0.2 else { continue }
            arcs.append((arc(m), max(0, 1 - k / 4) * 0.85 * t.visibility))
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            for (p, a) in arcs { layer.stroke(p, with: .color(color.opacity(a * 0.8)), lineWidth: 2) }
        }
        for (p, a) in arcs { ctx.stroke(p, with: .color(color.opacity(a)), lineWidth: 1) }
    }

    // MARK: Trail and markers

    private func drawTrail(_ ctx: GraphicsContext, _ trail: [Double], _ t: TrackDisplay, _ color: Color) {
        guard trail.count > 1 else { return }
        let history = trail.dropLast()
        let n = Double(history.count)
        for (i, m) in history.enumerated() {
            let fresh = (Double(i) + 1) / n          // older → 0, newer → 1
            let p = point(0, m)
            let r = 1 + 1.4 * fresh
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity((0.12 + 0.5 * fresh) * max(t.visibility, 0.4))))
        }
    }

    private func drawMarkers(_ ctx: GraphicsContext) {
        let shown = [(s.moving, TargetKind.moving), (s.still, TargetKind.still)]
            .filter { $0.0.visibility > 0.02 }
        var labelYs: [CGFloat] = []
        for (index, item) in shown.enumerated() {
            let (t, kind) = item
            let color = Theme.color(for: kind)
            let pulse = kind == .still ? 0.55 + 0.45 * (0.5 + 0.5 * sin(time * 2.6)) : 1
            let a = t.visibility * pulse
            let p = point(0, t.distance)

            var cross = Path()
            cross.move(to: CGPoint(x: p.x - 12, y: p.y)); cross.addLine(to: CGPoint(x: p.x - 3, y: p.y))
            cross.move(to: CGPoint(x: p.x + 3, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 12, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 12)); cross.addLine(to: CGPoint(x: p.x, y: p.y - 3))
            cross.move(to: CGPoint(x: p.x, y: p.y + 3)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 12))
            let ring = Path(ellipseIn: CGRect(x: p.x - 6.5, y: p.y - 6.5, width: 13, height: 13))

            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                           with: .color(color.opacity(0.55 * a)))
                layer.stroke(cross, with: .color(color.opacity(a)), lineWidth: 2)
            }
            ctx.stroke(ring, with: .color(color.opacity(a)), lineWidth: 1.5)
            ctx.stroke(cross, with: .color(color.opacity(a)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)),
                     with: .color(color.opacity(a)))

            // Label to the right; if it would collide with the other one, put it on the left.
            let collides = labelYs.contains { abs($0 - p.y) < 16 }
            labelYs.append(p.y)
            let label = Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(color.opacity(max(a, 0.5)))
            if collides {
                ctx.draw(label, at: CGPoint(x: p.x - 18, y: p.y), anchor: .trailing)
            } else {
                ctx.draw(label, at: CGPoint(x: p.x + 18, y: p.y), anchor: .leading)
            }
        }
    }

    /// Small chevron at the apex: you.
    private func drawApex(_ ctx: GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: origin.x, y: origin.y - 7))
        p.addLine(to: CGPoint(x: origin.x - 5, y: origin.y + 3))
        p.addLine(to: CGPoint(x: origin.x + 5, y: origin.y + 3))
        p.closeSubpath()
        ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
    }

    // MARK: Helpers

    /// Screen point for a bearing relative to "up" and a distance in meters.
    private func point(_ relBearing: Double, _ meters: Double) -> CGPoint {
        let u = Compass.unit(relBearing)
        let r = CGFloat(meters) * ppm
        return CGPoint(x: origin.x + u.dx * r, y: origin.y + u.dy * r)
    }

    private func arc(_ meters: Double) -> Path {
        var p = Path()
        let steps = 36
        for i in 0...steps {
            let a = -s.halfAngle + 2 * s.halfAngle * Double(i) / Double(steps)
            let pt = point(a, meters)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
