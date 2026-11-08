import Foundation
import Observation

/// What the wrists are told. First match wins (evaluated every 100 ms).
enum Cue: Equatable {
    case stop, left, right, forward, off

    var label: String {
        switch self {
        case .stop: "STOP"
        case .left: "TURN LEFT"
        case .right: "TURN RIGHT"
        case .forward: "FORWARD"
        case .off: "OFF"
        }
    }
}

struct CueLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let cue: Cue
    let detail: String
}

/// What the cue table looks at on each tick.
struct GuidanceInputs {
    /// Raw waist ultrasonic reading in cm (-1 = no echo, nil = no fresh data).
    var us: Int?
    /// Distance to the beacon in meters (UWB, or RSSI estimate when far).
    var distance: Double?
    /// Bearing relative to the phone's back, degrees (+ right); from the latch, so it stays
    /// valid when UWB direction is nil. nil until the first direction latches.
    var bearing: Double?
    /// No BLE and no UWB at all.
    var outOfRange = false
    /// Gyro heading (degrees), for the obstacle detour.
    var heading: Double = 0
    /// Time of the waist frame `us` came from (the detour debounce counts new frames).
    var usFrameTime: Date?
}

/// Picks the cue (normal guidance, overridden by the obstacle detour), turns it into a
/// haptic pattern and drives the bracelets with Afin's 2-byte protocol ([cue, param] to …def1,
/// without response). Runs every 50 ms: writes immediately on change, caps turn-intensity
/// updates at 10/s, and re-sends each bracelet's command every 1 s as a keep-alive (the boards
/// stop by themselves after 2 s of silence). Haptics are off until the wearer turns them on;
/// the [LOG] test panel can drive the bracelets either way.
@MainActor
@Observable
final class GuidanceEngine {
    nonisolated static let tickInterval: TimeInterval = HapticPattern.rippleStep
    nonisolated static let keepAlive: TimeInterval = 1.0
    nonisolated static let minTurnUpdate: TimeInterval = 0.1

    private(set) var cue: Cue = .off
    private(set) var log: [CueLogEntry] = []
    /// DIRECT / BLOCKED / DETOUR L / DETOUR R, and the detour heading, for [LOG] and the footer.
    private(set) var detourState = "DIRECT"
    private(set) var detourSide: Int?
    private(set) var detourHeading: Double?
    /// Exactly what's being sent: FORWARD / TURN LEFT 180 / STOP / DETOUR LEFT / OFF.
    private(set) var sentLabel = "OFF"
    /// [HAPTICS ON/OFF] on the main screen. Off by default: [0,0] to both.
    var hapticsEnabled = false
    /// Active button in the [LOG] test panel; overrides navigation until cleared.
    private(set) var test: HapticTest?
    var testIntensity: Double = 180

    /// The gyro heading frame changed: detour headings in the old frame are meaningless.
    func headingFrameChanged() {
        planner.reset()
    }

    @ObservationIgnored private let boards: BoardLink
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSent: [Side: BraceletCommand] = [:]
    @ObservationIgnored private var lastSentAt: [Side: Date] = [:]
    @ObservationIgnored private var planner = DetourPlanner()
    @ObservationIgnored private var normalCue: Cue = .off
    @ObservationIgnored private var lastUSFrame: Date?
    @ObservationIgnored private var rippleStart = Date()
    @ObservationIgnored private var wasRipple = false
    @ObservationIgnored var inputs: @MainActor () -> GuidanceInputs = { GuidanceInputs() }

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
        for side in Side.allCases { boards.write(.off, to: side) }
    }

    func clearLog() { log.removeAll() }

    /// Test panel: send this pattern and keep it alive until another is chosen or cleared.
    func setTest(_ t: HapticTest?) { test = t }

    // MARK: - Cue table

    /// Normal guidance (before the obstacle detour); `current` is the previous normal cue
    /// (forward hysteresis: enter at 15°, exit at 25°). Obstacles are handled by DetourPlanner.
    nonisolated static func select(_ i: GuidanceInputs, current: Cue) -> Cue {
        if let d = i.distance, d < 1.0 { return .stop }              // arrival is a stop
        if i.outOfRange { return .off }
        guard let b = i.bearing else { return .off }                 // no fix yet
        let forwardLimit = current == .forward ? 25.0 : 15.0
        if abs(b) <= forwardLimit { return .forward }
        return b < 0 ? .left : .right
    }

    /// Turn intensity: 255 at 15° off, falling to 70 at 90° (louder as you get it right).
    nonisolated static func intensity(_ bearing: Double) -> UInt8 {
        let a = min(90, max(15, abs(bearing)))
        return UInt8((70 + 185 * (1 - (a - 15) / 75)).rounded())
    }

    /// `turnBearing` sets the turn intensity; nil = the detour scan's fixed intensity.
    nonisolated static func pattern(_ cue: Cue, turnBearing: Double?) -> HapticPattern {
        let level = turnBearing.map(intensity) ?? DetourPlanner.scanIntensity
        switch cue {
        case .stop: return .stop
        case .forward: return .forwardRipple
        case .off: return .off
        case .left: return .left(level)          // negative bearing → Bracelet-L
        case .right: return .right(level)
        }
    }

    // MARK: - Tick

    private func tick(now: Date) {
        if let test {
            resetNavigation()                         // never resume a stale detour after a test
            let p = test.pattern(intensity: UInt8(min(255, max(70, testIntensity.rounded()))))
            publish(p.label, for: p)
            send(p, now: now, acknowledged: true)     // with response, so the panel can show ✓
            return
        }
        guard hapticsEnabled else {
            resetNavigation()
            publish(HapticPattern.off.label, for: .off)
            send(.off, now: now, acknowledged: false)
            return
        }

        let i = inputs()
        normalCue = Self.select(i, current: normalCue)
        let fresh = i.usFrameTime != nil && i.usFrameTime != lastUSFrame
        lastUSFrame = i.usFrameTime
        let out = planner.step(us: i.us, distance: i.distance, bearing: i.bearing, heading: i.heading,
                               normal: normalCue, now: now, usFresh: fresh)
        let next = out.cue
        let state = planner.label
        if state != detourState {
            detourState = state
            Log.uwb(.firefighter, "obstacle: \(state)\(planner.detourHeading.map { String(format: " heading %.0f°", $0) } ?? "")"
                    + "\(i.us.map { " us \($0) cm" } ?? "")")
        }
        if planner.detourSide != detourSide { detourSide = planner.detourSide }
        if planner.detourHeading != detourHeading { detourHeading = planner.detourHeading }
        if next != cue {
            cue = next
            record(next, i, now: now)
        }
        let p = Self.pattern(next, turnBearing: out.turnBearing)
        if next != .stop, let side = detourSide {
            // Name the wrist actually being driven (it can differ from the sweep side on overshoot).
            let dir = next == .left ? -1 : (next == .right ? 1 : side)
            publish(dir < 0 ? "DETOUR LEFT" : "DETOUR RIGHT", for: p)
        } else {
            publish(p.label, for: p)
        }
        send(p, now: now, acknowledged: false)
    }

    private func resetNavigation() {
        planner.reset()
        normalCue = .off
        if cue != .off { cue = .off }
        if detourState != "DIRECT" { detourState = "DIRECT" }
        if detourSide != nil { detourSide = nil }
        if detourHeading != nil { detourHeading = nil }
    }

    /// Footer text: what's being sent, flagged if a bracelet it needs isn't connected.
    private func publish(_ base: String, for p: HapticPattern) {
        let down = p.activeSides.filter { !boards.isReady($0.board) }
        let suffix = down.isEmpty ? "" : (down.count == 2 ? " (NO BRACELETS)" : " (\(down[0].short) DOWN)")
        let label = base + suffix
        if label != sentLabel { sentLabel = label }
    }

    private func send(_ p: HapticPattern, now: Date, acknowledged: Bool) {
        if p.isRipple, !wasRipple { rippleStart = now }
        wasRipple = p.isRipple
        for (side, cmd) in p.commands(rippleElapsed: now.timeIntervalSince(rippleStart)) {
            guard boards.isReady(side.board) else {
                lastSent[side] = nil            // resend immediately once it reconnects
                continue
            }
            let age = now.timeIntervalSince(lastSentAt[side] ?? .distantPast)
            let changed = lastSent[side] != cmd
            let stale = age >= Self.keepAlive
            guard changed || stale else { continue }
            // Cap turn-intensity updates at 10/s (a change of cue is never delayed).
            if changed, !stale, let last = lastSent[side], last.cue == 3, cmd.cue == 3, age < Self.minTurnUpdate { continue }
            if boards.write(cmd, to: side, acknowledged: acknowledged) {
                lastSent[side] = cmd
                lastSentAt[side] = now
            }
        }
    }

    private func record(_ c: Cue, _ i: GuidanceInputs, now: Date) {
        var parts: [String] = []
        if let us = i.us, us >= 0 { parts.append("us \(us) cm") }
        if let d = i.distance { parts.append(String(format: "%.1f m", d)) }
        if let b = i.bearing { parts.append(String(format: "%+.0f°", b)) }
        if i.outOfRange { parts.append("out of range") }
        log.insert(CueLogEntry(time: now, cue: c, detail: parts.joined(separator: " · ")), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
        Log.uwb(.firefighter, "cue: \(c.label) (\(parts.joined(separator: ", ")))")
    }
}
