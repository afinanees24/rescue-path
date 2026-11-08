import Foundation

/// Obstacle detour from the forward waist ultrasonic (`us`). First match wins:
///   a. distance to target < 1.0 m → STOP (arrived)
///   b. us < 30 cm → STOP (hard safety stop)
///   c. BLOCKED: us < 80 cm while guidance says FORWARD →
///        STOP 0.5 s → turn toward the target's side (or the side it was last off-centre)
///        while the sensor scans → first heading with us > 120 cm becomes the DETOUR heading
///        → FORWARD along it → after ~2.5 s, or as soon as facing the target shows
///        us > 120 cm, back to the target. Turned > 90° with no gap → try the other side.
///   d. otherwise normal guidance.
struct DetourPlanner {
    enum State: Equatable {
        case direct
        case blocked(until: Date, side: Int)
        case scanning(side: Int, start: Double, triedOther: Bool)
        case detour(heading: Double, side: Int, until: Date)
    }

    static let blockedCm = 80.0
    static let hardStopCm = 30.0
    static let clearCm = 120.0
    static let stopTime: TimeInterval = 0.5
    static let detourTime: TimeInterval = 2.5
    static let scanIntensity: UInt8 = 200
    /// A gap must read clear for this many consecutive ticks (one no-echo frame isn't a gap).
    static let clearTicksNeeded = 3
    /// Extra turn past the gap's first clear heading, so the body clears the edge. Larger
    /// than the 15° forward dead-band, so the wearer is actually turned the extra amount.
    static let detourMargin = 20.0

    private(set) var state: State = .direct
    /// +1 right, −1 left: which side the target was last off-centre.
    private(set) var lastOffSide = 1
    private var cooldownUntil: Date = .distantPast
    private var clearTicks = 0
    private var facingClearTicks = 0

    /// What to send. `turnBearing` sets the turn intensity (nil = fixed scan intensity).
    struct Output: Equatable {
        var cue: Cue
        var turnBearing: Double?
    }

    var label: String {
        switch state {
        case .direct: "DIRECT"
        case .blocked: "BLOCKED"
        case .scanning(let side, _, _), .detour(_, let side, _): side < 0 ? "DETOUR L" : "DETOUR R"
        }
    }

    /// Side while scanning or on a detour (for "DETOUR LEFT/RIGHT"), else nil.
    var detourSide: Int? {
        switch state {
        case .scanning(let side, _, _), .detour(_, let side, _): side
        default: nil
        }
    }

    var detourHeading: Double? {
        if case .detour(let h, _, _) = state { return h }
        return nil
    }

    mutating func reset() {
        state = .direct
        cooldownUntil = .distantPast
        clearTicks = 0
        facingClearTicks = 0
    }

    /// - us: waist ultrasonic cm (−1 = no echo = clear, nil = no waist data)
    /// - bearing: target bearing relative to the phone's back (+ right), nil without a fix
    /// - normal: the cue normal guidance would give (forward / turn / off)
    /// - usFresh: `us` is a new waist frame since the last step (debounce counts frames, not ticks)
    mutating func step(us: Int?, distance: Double?, bearing: Double?, heading: Double,
                       normal: Cue, now: Date, usFresh: Bool = true) -> Output {
        if let b = bearing, abs(b) > 3 { lastOffSide = b > 0 ? 1 : -1 }

        // a. Arrived.
        if let d = distance, d < 1.0 {
            state = .direct
            return Output(cue: .stop)
        }
        guard let raw = us else {
            state = .direct                 // no waist data: plain guidance
            return Output(cue: normal, turnBearing: bearing)
        }
        let u = raw < 0 ? 400.0 : Double(raw)
        var out = stateStep(u: u, fresh: usFresh, bearing: bearing, heading: heading, normal: normal, now: now)
        // b. Hard safety stop: never FORWARD (or drift) under 30 cm, but keep the state
        //    machine running so turn-in-place scan cues still get through.
        if u > 0, u < Self.hardStopCm, out.cue == .forward || out.cue == .off {
            out = Output(cue: .stop)
        }
        return out
    }

    private mutating func stateStep(u: Double, fresh: Bool, bearing: Double?, heading: Double, normal: Cue,
                                    now: Date) -> Output {
        let normalOut = Output(cue: normal, turnBearing: bearing)
        switch state {
        case .direct:
            // Blocked only when guidance wants FORWARD into < 80 cm. (Under 30 cm the hard-stop
            // veto already blocks FORWARD; turning in place is left alone.)
            let blockedAhead = u < Self.blockedCm && normal == .forward
            if blockedAhead {
                if now < cooldownUntil { return Output(cue: .stop) }
                let side = bearing.map { abs($0) > 3 ? ($0 > 0 ? 1 : -1) : lastOffSide } ?? lastOffSide
                state = .blocked(until: now.addingTimeInterval(Self.stopTime), side: side)
                return Output(cue: .stop)
            }
            return normalOut

        case .blocked(let until, let side):
            if now < until { return Output(cue: .stop) }
            clearTicks = 0
            state = .scanning(side: side, start: heading, triedOther: false)
            return scan(side: side)

        case .scanning(let side, let start, let triedOther):
            if fresh { clearTicks = u > Self.clearCm ? clearTicks + 1 : 0 }
            if clearTicks >= Self.clearTicksNeeded {
                let dh = wrapDegrees(heading + Double(side) * Self.detourMargin)
                facingClearTicks = 0
                state = .detour(heading: dh, side: side, until: now.addingTimeInterval(Self.detourTime))
                return turnOrForward(toward: dh, heading: heading)
            }
            // How far I've turned toward the scan side since the scan started.
            let turned = wrapDegrees(heading - start) * Double(side)
            if turned > 90 {
                if !triedOther {
                    // No gap within 90°: sweep the other way, up to 90° past the start.
                    clearTicks = 0
                    state = .scanning(side: -side, start: start, triedOther: true)
                    return scan(side: -side)
                }
                // Both sides blocked: stop, wait, then try again.
                state = .direct
                cooldownUntil = now.addingTimeInterval(2)
                return Output(cue: .stop)
            }
            return scan(side: side)

        case .detour(let dh, let side, let until):
            if u < Self.blockedCm {
                state = .blocked(until: now.addingTimeInterval(Self.stopTime), side: side)
                return Output(cue: .stop)
            }
            let facingTarget = bearing.map { abs($0) <= 15 } ?? false
            if fresh { facingClearTicks = facingTarget && u > Self.clearCm ? facingClearTicks + 1 : 0 }
            if now >= until || facingClearTicks >= Self.clearTicksNeeded {
                state = .direct
                return normalOut
            }
            return turnOrForward(toward: dh, heading: heading)
        }
    }

    private func turnOrForward(toward dh: Double, heading: Double) -> Output {
        let rel = wrapDegrees(dh - heading)
        if abs(rel) <= 15 { return Output(cue: .forward) }
        return Output(cue: rel < 0 ? .left : .right, turnBearing: rel)
    }

    private func scan(side: Int) -> Output {
        Output(cue: side < 0 ? .left : .right, turnBearing: nil)
    }
}
