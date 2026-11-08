import Foundation
import Observation

/// Afin's rule table. Evaluated top to bottom every 100 ms; the first match wins.
enum GuidanceRule: Int, CaseIterable {
    case stop = 1, onTarget, left, right, forward, sweep, idle

    var cue: String {
        switch self {
        case .stop: "STOP"
        case .onTarget: "ON TARGET"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .forward: "FORWARD"
        case .sweep: "SWEEP"
        case .idle: "IDLE"
        }
    }
}

struct RuleLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let rule: GuidanceRule
    let detail: String
}

/// What the rules look at on each tick.
struct GuidanceInputs {
    /// Raw waist ultrasonic reading in cm (-1 = no echo, nil = no fresh data).
    var us: Int?
    /// Smoothed target distance in meters.
    var distance: Double?
    /// Smoothed target bearing in degrees: 0 ahead, + right, − left. nil = no direction.
    var bearing: Double?
    /// True while the target source is running/connected (so "no fix" means SWEEP, not idle).
    var sourceActive: Bool
}

/// Runs the rule table and drives the bracelets. Writes only when the pattern changes
/// or its period elapses, so the BLE queue never backs up.
@MainActor
@Observable
final class GuidanceEngine {
    nonisolated static let tickInterval: TimeInterval = 0.1

    private(set) var rule: GuidanceRule = .idle
    private(set) var log: [RuleLogEntry] = []

    @ObservationIgnored private let boards: BoardLink
    @ObservationIgnored private var cycleStart: Date?
    @ObservationIgnored private var cyclePeriod: TimeInterval?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var inputs: @MainActor () -> GuidanceInputs = { GuidanceInputs(sourceActive: false) }

    init(boards: BoardLink) {
        self.boards = boards
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: Date()) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
    }

    func clearLog() { log.removeAll() }

    // MARK: - Rules

    func evaluate(_ i: GuidanceInputs) -> GuidanceRule {
        Self.evaluate(i, current: rule)
    }

    /// Pure rule check; `current` is the active rule (for the ±20°/12° hysteresis).
    nonisolated static func evaluate(_ i: GuidanceInputs, current rule: GuidanceRule) -> GuidanceRule {
        // 1. Ultrasonic always wins.
        if let us = i.us, us > 0, us < 60 { return .stop }
        // 2. Close enough.
        if let d = i.distance, d < 1.0 { return .onTarget }
        // 3–5. Steer by bearing, with hysteresis: enter LEFT/RIGHT at 20°, leave at 12°.
        if let b = i.bearing, i.distance != nil {
            let leftEdge = rule == .left ? -12.0 : -20.0
            let rightEdge = rule == .right ? 12.0 : 20.0
            if b < leftEdge { return .left }
            if b > rightEdge { return .right }
            return .forward
        }
        // 6. Source running but no direction: sweep. 7. Nothing to go on: idle.
        return i.sourceActive ? .sweep : .idle
    }

    // MARK: - Tick

    private func tick(now: Date) {
        let i = inputs()
        let next = evaluate(i)
        if next != rule {
            rule = next
            record(next, i, now: now)
            startCycle(now: now, inputs: i)
        } else if let start = cycleStart, let period = cyclePeriod,
                  now.timeIntervalSince(start) >= period - 0.02 {
            startCycle(now: now, inputs: i)
        }
    }

    private func record(_ r: GuidanceRule, _ i: GuidanceInputs, now: Date) {
        var parts: [String] = []
        if let us = i.us, us >= 0 { parts.append("us \(us) cm") }
        if let d = i.distance { parts.append(String(format: "%.1f m", d)) }
        if let b = i.bearing { parts.append(String(format: "%+.0f°", b)) }
        log.insert(RuleLogEntry(time: now, rule: r, detail: parts.joined(separator: " · ")), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }

    // MARK: - Patterns

    private struct Event {
        let side: Side
        let offset: TimeInterval
        let cmd: BuzzCommand
    }

    private func pattern(for r: GuidanceRule, _ i: GuidanceInputs) -> (period: TimeInterval?, events: [Event]) {
        switch r {
        case .stop:          // FF 19 both, every 300 ms
            let c = BuzzCommand(intensity: 0xFF, duration: 0x19)
            return (0.3, [Event(side: .left, offset: 0, cmd: c), Event(side: .right, offset: 0, cmd: c)])
        case .onTarget:      // FF 0A ×2, 150 ms apart, both (repeat every 1.5 s: our call)
            let c = BuzzCommand(intensity: 0xFF, duration: 0x0A)
            return (1.5, [Event(side: .left, offset: 0, cmd: c), Event(side: .right, offset: 0, cmd: c),
                          Event(side: .left, offset: 0.15, cmd: c), Event(side: .right, offset: 0.15, cmd: c)])
        case .left:          // B4 19 left, every 200 ms (steady)
            return (0.2, [Event(side: .left, offset: 0, cmd: BuzzCommand(intensity: 0xB4, duration: 0x19))])
        case .right:         // B4 19 right, every 200 ms (steady)
            return (0.2, [Event(side: .right, offset: 0, cmd: BuzzCommand(intensity: 0xB4, duration: 0x19))])
        case .forward:       // 78 0A both; period = clamp(distance × 200 ms, 200, 1000)
            let c = BuzzCommand(intensity: 0x78, duration: 0x0A)
            let period = min(1.0, max(0.2, (i.distance ?? 5) * 0.2))
            return (period, [Event(side: .left, offset: 0, cmd: c), Event(side: .right, offset: 0, cmd: c)])
        case .sweep:         // 64 14 left, right 400 ms later (cycle 800 ms: our call)
            let c = BuzzCommand(intensity: 0x64, duration: 0x14)
            return (0.8, [Event(side: .left, offset: 0, cmd: c), Event(side: .right, offset: 0.4, cmd: c)])
        case .idle:          // off: motors stop on their own
            return (nil, [])
        }
    }

    private func startCycle(now: Date, inputs i: GuidanceInputs) {
        generation += 1
        let (period, events) = pattern(for: rule, i)
        cycleStart = period == nil ? nil : now
        cyclePeriod = period
        let gen = generation
        for e in events {
            if e.offset <= 0 {
                boards.write(e.cmd, to: e.side)
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(e.offset * 1_000_000_000))
                    guard let self, self.generation == gen else { return }
                    self.boards.write(e.cmd, to: e.side)
                }
            }
        }
    }
}
