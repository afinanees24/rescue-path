import SwiftUI

/// Main screen: a minimal, heading-up tactical handheld radar.
struct RadarScreen: View {
    let store: RadarStore
    var onExit: () -> Void = {}
    @State private var showMap = false
    @State private var showDebug = false
    @State private var rotateBase: Double?

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
        .fullScreenCover(isPresented: $showMap) {
            MapScreen(store: store)
        }
        .sheet(isPresented: $showDebug) {
            DebugPanel(store: store, onExit: onExit)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                tacText("FF-RADAR", 14, .bold).foregroundStyle(Theme.ink)
                tacText(subtitle, 11).foregroundStyle(Theme.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 10) {
                    pip("W", store.boards.isReady(.waist))
                    pip("L", store.boards.isReady(.left))
                    pip("R", store.boards.isReady(.right))
                    pip("U", store.uwb.isLinked)
                }
                tacText("\(store.sourceKind.label) · 5M", 11)
                    .foregroundStyle(store.sourceActive ? Theme.cyan : Theme.dim)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.6) { showDebug = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Long-press for the debug panel")
    }

    /// Connection pip: filled cyan when connected, hollow when not.
    private func pip(_ letter: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? Theme.cyan : Color.clear)
                .overlay(Circle().stroke(on ? Theme.cyan : Theme.dim, lineWidth: 1))
                .frame(width: 7, height: 7)
                .glow(on ? Theme.cyan : .clear, radius: 2)
            tacText(letter, 11, .bold).foregroundStyle(on ? Theme.ink : Theme.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(letter) \(on ? "connected" : "not connected")")
    }

    private var subtitle: String {
        if store.boards.bluetooth != "ON" { return "BT \(store.boards.bluetooth)" }
        if store.sourceKind == .uwb { return "UWB \(store.uwb.status.label)" }
        return "SEARCH MODE"
    }

    // MARK: Scope

    private var scope: some View {
        TimelineView(.animation) { tl in
            let snap = ScopeSnapshot(
                heading: store.displayHeading,
                firefighter: store.firefighter,
                target: store.target,
                providesBearing: store.providesBearing,
                trail: store.trail,
                blips: store.blips,
                obstacleCm: store.obstacleCm,
                obstacleVisibility: store.obstacleVisibility,
                halfAngle: RadarStore.halfAngle,
                range: RadarStore.range)
            let date = tl.date
            Canvas { ctx, size in
                ScopeRenderer(s: snap, now: date, size: size).draw(ctx)
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
        var parts = ["Guidance \(store.guidance.rule.cue)."]
        if let d = store.fix.distance { parts.append(String(format: "Target %.1f metres", d)) }
        if let b = store.fix.bearing { parts.append(String(format: "bearing %+.0f degrees", b)) }
        return parts.joined(separator: " ")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                tacText("TGT \(store.fix.distance == nil ? 0 : 1)", 12, .bold).foregroundStyle(Theme.ink)
                tacText(targetText, 11).foregroundStyle(store.fix.distance == nil ? Theme.dim : Theme.cyan)
            }
            .frame(width: 96, alignment: .leading)

            cue.frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 5) {
                TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                    let us = store.boards.currentUS(now: tl.date)
                    tacText(us.map { $0 < 0 ? "US --" : "US \($0)cm" } ?? "US --", 12, .bold)
                        .foregroundStyle(us.map { $0 > 0 && $0 < 60 } == true ? Theme.red : Theme.ink)
                }
                tacText(store.boards.waistRate > 0 ? "RX \(Int(store.boards.waistRate.rounded()))Hz" : "RX --", 11)
                    .foregroundStyle(store.boards.waistRate > 0 ? Theme.line : Theme.dim)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    private var targetText: String {
        guard let d = store.fix.distance else { return "NO FIX" }
        if let b = store.fix.bearing { return String(format: "%.1fm %+.0f°", d, b) }
        return String(format: "%.1fm", d)
    }

    /// The active rule, mirroring what the wrists feel.
    private var cue: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { tl in
            let rule = store.guidance.rule
            let blinkOn = rule != .stop || tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) < 0.4
            let color: Color = rule == .stop ? Theme.red : (rule == .idle ? Theme.dim : (rule == .sweep ? Theme.ink : Theme.cyan))
            tacText(cueText(rule), 24, .bold)
                .foregroundStyle(color)
                .glow(rule == .idle ? .clear : color, radius: 4)
                .opacity(blinkOn ? 1 : 0.25)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private func cueText(_ rule: GuidanceRule) -> String {
        switch rule {
        case .stop: "STOP"
        case .onTarget: "ON TARGET"
        case .left: "◀ LEFT"
        case .right: "RIGHT ▶"
        case .forward: "▲ FORWARD"
        case .sweep: "SWEEP"
        case .idle: "--"
        }
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

            Menu {
                Picker("Target source", selection: Binding(get: { store.sourceKind },
                                                           set: { store.setSource($0) })) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
            } label: {
                tacText("[SRC \(store.sourceKind.label)]", 13, .bold)
                    .foregroundStyle(Theme.line)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Target source \(store.sourceKind.label)")

            Spacer()

            Button {
                showMap = true
            } label: {
                tacText("[MAP]", 13, .bold)
                    .foregroundStyle(Theme.line)
                    .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open floor plan and rule log")
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

// MARK: - Drawing

struct ScopeSnapshot {
    let heading: Double
    let firefighter: CGPoint
    let target: TargetDisplay
    let providesBearing: Bool
    let trail: [TrailPoint]
    let blips: [Blip]
    let obstacleCm: Double
    let obstacleVisibility: Double
    let halfAngle: Double
    let range: Double
}

/// Polar scope, firefighter at the bottom centre, 0° straight up (heading-up).
struct ScopeRenderer {
    let s: ScopeSnapshot
    let now: Date
    let size: CGSize

    private var time: Double { now.timeIntervalSinceReferenceDate }

    /// Scope radius in points, as large as fits the width and height.
    private var radius: CGFloat {
        let byWidth = (size.width / 2 - 4) / CGFloat(sin(s.halfAngle * .pi / 180))
        let byHeight = size.height - 40
        return max(40, min(byWidth, byHeight))
    }

    /// Apex: bottom centre, with the wedge vertically centred in the space.
    private var origin: CGPoint {
        CGPoint(x: size.width / 2, y: min(size.height - 16, size.height / 2 + radius / 2 + 8))
    }

    private var ppm: CGFloat { radius / CGFloat(s.range) }

    func draw(_ ctx: GraphicsContext) {
        drawGrid(ctx)
        drawNoise(ctx)
        drawBlips(ctx)
        drawObstacle(ctx)
        drawRangeRing(ctx)
        drawTrail(ctx)
        drawTarget(ctx)
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
        for m in 1..<Int(s.range) { rings.addPath(arc(Double(m))) }

        ctx.stroke(inner, with: .color(Theme.ink.opacity(0.2)), lineWidth: 1)
        ctx.stroke(rings, with: .color(Theme.ink.opacity(0.28)), lineWidth: 1)
        ctx.stroke(outer, with: .color(Theme.line), lineWidth: 1)

        for m in 1...Int(s.range) {
            let y = origin.y - CGFloat(m) * ppm - 7
            ctx.draw(Text("\(m)m")
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
            let p = point(-s.halfAngle + 2 * s.halfAngle * u, 0.3 + (s.range - 0.3) * sqrt(v))
            ctx.fill(Path(CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)),
                     with: .color(Theme.ink.opacity(0.08 + 0.32 * a)))
        }
    }

    // MARK: Scan blips (world-fixed, rotate as you turn)

    private func drawBlips(_ ctx: GraphicsContext) {
        for b in s.blips {
            let d = s.firefighter.distance(to: b.position)
            guard d <= s.range + 0.5 else { continue }
            let rel = Compass.delta(Compass.bearing(from: s.firefighter, to: b.position), s.heading)
            let p = point(rel, d)
            guard p.x >= 0, p.x <= size.width, p.y >= 0, p.y <= size.height else { continue }
            let alpha = max(0, 1 - now.timeIntervalSince(b.time) / RadarStore.blipLifetime)
            ctx.fill(Path(CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                     with: .color(Theme.cyan.opacity(alpha)))
        }
    }

    // MARK: Target

    private func drawTarget(_ ctx: GraphicsContext) {
        let t = s.target
        guard t.visibility > 0.02 else { return }
        let bearing = s.providesBearing ? t.bearing : 0
        let a = s.providesBearing ? t.visibility * t.bearingVisibility : t.visibility
        guard a > 0.02 else { return }
        let label = t.distance > s.range ? String(format: "01 %.0fm", t.distance) : "01"
        drawMarker(ctx, at: point(bearing, min(t.distance, s.range)), color: Theme.cyan, alpha: a, label: label)
    }

    /// When direction is nil (or the source is radar), keep a ring at the distance:
    /// 3 stacked thin arcs across the wedge, fading outward.
    private func drawRangeRing(_ ctx: GraphicsContext) {
        let t = s.target
        let a = s.providesBearing ? t.visibility * (1 - t.bearingVisibility) : t.visibility
        guard a > 0.02 else { return }
        let step = Double(5 / ppm)
        let drift = (time * 0.8).truncatingRemainder(dividingBy: 1)
        var arcs: [(Path, Double)] = []
        for i in 0..<4 {
            let k = Double(i) + drift
            let m = min(t.distance, s.range) + k * step
            guard m <= s.range + 0.2 else { continue }
            arcs.append((arc(m), max(0, 1 - k / 4) * 0.85 * a))
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            for (p, o) in arcs { layer.stroke(p, with: .color(Theme.cyan.opacity(o * 0.8)), lineWidth: 2) }
        }
        for (p, o) in arcs { ctx.stroke(p, with: .color(Theme.cyan.opacity(o)), lineWidth: 1) }
    }

    /// Fading dots at the marker's last positions.
    private func drawTrail(_ ctx: GraphicsContext) {
        guard s.trail.count > 1 else { return }
        let history = s.trail.dropLast()
        let n = Double(history.count)
        for (i, tp) in history.enumerated() {
            let fresh = (Double(i) + 1) / n
            let p = point(tp.bearing, min(tp.distance, s.range))
            let r = 1 + 1.4 * fresh
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(Theme.cyan.opacity((0.12 + 0.5 * fresh) * max(s.target.visibility, 0.4))))
        }
    }

    /// Waist ultrasonic: a short arc straight ahead at `us` cm; red under 60 cm.
    private func drawObstacle(_ ctx: GraphicsContext) {
        guard s.obstacleVisibility > 0.02 else { return }
        let meters = min(s.obstacleCm / 100, s.range)
        let close = s.obstacleCm < 60
        let color = close ? Theme.red : Theme.ink
        let a = s.obstacleVisibility * (close ? 1 : 0.75)
        let bar = arc(meters, from: -12, to: 12)
        if close {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.stroke(bar, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
            }
        }
        ctx.stroke(bar, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
        ctx.draw(Text("\(Int(s.obstacleCm.rounded()))cm")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(color.opacity(a)),
                 at: point(14, meters), anchor: .leading)
    }

    private func drawMarker(_ ctx: GraphicsContext, at p: CGPoint, color: Color, alpha a: Double, label: String) {
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
        ctx.draw(Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(color.opacity(max(a, 0.5))),
                 at: CGPoint(x: p.x + 18, y: p.y), anchor: .leading)
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

    private func arc(_ meters: Double, from b0: Double? = nil, to b1: Double? = nil) -> Path {
        let lo = b0 ?? -s.halfAngle
        let hi = b1 ?? s.halfAngle
        var p = Path()
        let steps = 36
        for i in 0...steps {
            let pt = point(lo + (hi - lo) * Double(i) / Double(steps), meters)
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
