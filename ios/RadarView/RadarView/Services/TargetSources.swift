import CoreGraphics
import Foundation

struct SourceContext {
    let now: Date
    let dt: Double
    let firefighter: CGPoint
    let heading: Double
    /// True once the compass has a reading (or there is no compass / manual heading).
    let headingReady: Bool
}

/// Something that reports distance (and maybe bearing) to the person being searched for.
@MainActor
protocol TargetSource: AnyObject {
    var kind: SourceKind { get }
    /// False for the radar: it measures distance only, so the target sits on the centre line.
    var providesBearing: Bool { get }
    /// Running/connected. With no fix the rules SWEEP; when inactive they go idle.
    var isActive: Bool { get }
    var fix: TargetFix { get }
    /// Latest raw reading (for the world-position tracker); nil if the source can't place one.
    var latestReading: TargetReading? { get }
    func start()
    func stop()
    func tick(_ context: SourceContext)
}

// MARK: - UWB (default)

/// NearbyInteraction distance + direction to the beacon phone, 5-sample smoothed.
@MainActor
final class UWBTargetSource: TargetSource {
    let kind = SourceKind.uwb
    let providesBearing = true
    let link: UWBLink
    private var smoother = FixSmoother()
    private var fresh = false

    init(link: UWBLink) { self.link = link }

    var isActive: Bool { link.isLinked }
    var fix: TargetFix { fresh ? smoother.fix : .none }

    var latestReading: TargetReading? {
        guard let t = link.lastUpdate, let d = link.distance else { return nil }
        return TargetReading(distance: d, bearing: link.bearing, time: t)
    }

    func start() {
        link.onSample = { [weak self] distance, bearing in
            self?.smoother.push(distance: distance, bearing: bearing)
        }
        link.start()
    }

    func stop() {
        link.onSample = nil
        link.stop()
        smoother.reset()
        fresh = false
    }

    func tick(_ c: SourceContext) {
        fresh = link.isFresh(now: c.now)
        if !fresh { smoother.reset() }
    }
}

// MARK: - Radar (waist JSON)

/// rd/re from the waist unit when rp == 1. Distance only.
@MainActor
final class RadarTargetSource: TargetSource {
    let kind = SourceKind.radar
    let providesBearing = false
    private let boards: BoardLink
    private var smoother = FixSmoother()
    private var lastFrameAt: Date?
    private(set) var isActive = false

    init(boards: BoardLink) { self.boards = boards }

    var fix: TargetFix { isActive ? TargetFix(distance: smoother.fix.distance, bearing: nil) : .none }
    /// The radar has no direction, so it can't be placed in the world; drawn on the centre line instead.
    var latestReading: TargetReading? { nil }

    func start() { smoother.reset() }
    func stop() { smoother.reset(); isActive = false }

    func tick(_ c: SourceContext) {
        guard let w = boards.freshWaist(now: c.now), let t = boards.waistUpdatedAt else {
            isActive = false
            smoother.reset()
            return
        }
        isActive = w.rp == 1
        if t != lastFrameAt {
            lastFrameAt = t
            smoother.push(distance: (w.rp == 1 && w.rd > 0) ? Double(w.rd) / 100 : nil, bearing: nil)
        }
    }
}

// MARK: - Simulator

/// Reproduces the reference video: the target starts ~4.3 m ahead, slightly off centre,
/// walks toward you at ~0.6 m/s with a small side-to-side wobble, pauses on target,
/// then resets in front of wherever you face.
struct SimWalker {
    let origin: CGPoint
    let bearing: Double
    var distance = 4.3
    var time = 0.0
    var held = 0.0

    nonisolated static let speed = 0.6
    nonisolated static let stopDistance = 0.6
    nonisolated static let holdTime = 1.5

    init(origin: CGPoint, heading: Double) {
        self.origin = origin
        let side: Double = Bool.random() ? 1 : -1
        bearing = heading + side * Double.random(in: 5...10)
    }

    /// World position with a ~15 cm sideways wobble.
    var position: CGPoint {
        let base = origin.moved(bearing: bearing, distance: distance)
        return base.moved(bearing: bearing + 90, distance: 0.15 * sin(time * 2 * .pi / 1.6))
    }

    /// Advance; returns true when the walk is over and should restart.
    mutating func step(dt: Double) -> Bool {
        time += dt
        if distance > Self.stopDistance {
            distance = max(Self.stopDistance, distance - Self.speed * dt)
            return false
        }
        held += dt
        return held >= Self.holdTime
    }
}

/// Simulated beacon reporting like UWB: distance always, direction only within ±45°.
@MainActor
final class SimTargetSource: TargetSource {
    let kind = SourceKind.sim
    let providesBearing = true
    private var walker: SimWalker?
    private var smoother = FixSmoother()
    private var waitingSince: Date?
    private var accumulator = 0.0
    private(set) var latestReading: TargetReading?

    nonisolated static let directionHalfAngle = 45.0

    var isActive: Bool { walker != nil }
    var fix: TargetFix { walker != nil ? smoother.fix : .none }

    func start() {
        walker = nil
        waitingSince = nil
        latestReading = nil
        smoother.reset()
    }

    func stop() {
        walker = nil
        smoother.reset()
    }

    func tick(_ c: SourceContext) {
        if walker == nil {
            let since = waitingSince ?? c.now
            waitingSince = since
            // Wait (briefly) for the compass so "ahead" means where the phone points.
            guard c.headingReady || c.now.timeIntervalSince(since) > 2 else { return }
            walker = SimWalker(origin: c.firefighter, heading: c.heading)
        }
        guard var w = walker else { return }
        if w.step(dt: c.dt) {
            w = SimWalker(origin: c.firefighter, heading: c.heading)
        }
        walker = w

        accumulator += c.dt
        guard accumulator >= 0.1 else { return }        // ~10 Hz, like NI
        accumulator = accumulator.truncatingRemainder(dividingBy: 0.1)

        let pos = w.position
        let rel = Compass.delta(Compass.bearing(from: c.firefighter, to: pos), c.heading)
        let distance = max(0.1, c.firefighter.distance(to: pos) + Double.random(in: -0.04...0.04))
        let bearing = abs(rel) <= Self.directionHalfAngle ? rel + Double.random(in: -1.5...1.5) : nil
        smoother.push(distance: distance, bearing: bearing)
        latestReading = TargetReading(distance: distance, bearing: bearing, time: c.now)
    }
}
