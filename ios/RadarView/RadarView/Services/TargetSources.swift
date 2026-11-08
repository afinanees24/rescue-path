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

/// The existing simulator, reporting distance + bearing to the nearest person like UWB
/// would: direction only within ±45° of where the phone points, distance always.
@MainActor
final class SimTargetSource: TargetSource {
    let kind = SourceKind.sim
    let providesBearing = true
    let plan: FloorPlan
    private let simulator: RadarSimulator
    private var smoother = FixSmoother()
    private var seeded = false
    private var randomizeNext = false
    private var waitingSince: Date?
    private var accumulator = 0.0

    nonisolated static let directionHalfAngle = 45.0
    nonisolated static let maxRange = 15.0

    init(plan: FloorPlan) {
        self.plan = plan
        simulator = RadarSimulator(plan: plan)
    }

    var isActive: Bool { seeded }
    var fix: TargetFix { seeded ? smoother.fix : .none }
    var truth: [SimPerson] { simulator.truth }

    /// Place a new simulated beacon person next time the heading is known.
    func reseed(randomize: Bool) {
        seeded = false
        randomizeNext = randomize
        waitingSince = nil
        smoother.reset()
    }

    func start() { reseed(randomize: false) }
    func stop() { smoother.reset() }

    func tick(_ c: SourceContext) {
        if !seeded {
            let since = waitingSince ?? c.now
            waitingSince = since
            guard c.headingReady || c.now.timeIntervalSince(since) > 2 else { return }
            let offset = randomizeNext ? Double.random(in: -60...60) : Double.random(in: -12...12)
            simulator.seedBeacon(origin: c.firefighter, heading: c.heading + offset)
            seeded = true
        }
        simulator.step(dt: c.dt)
        accumulator += c.dt
        guard accumulator >= 0.1 else { return }        // ~10 Hz, like NI
        accumulator = accumulator.truncatingRemainder(dividingBy: 0.1)

        guard let hit = simulator.nearest(from: c.firefighter), hit.distance <= Self.maxRange else {
            smoother.push(distance: nil, bearing: nil)
            return
        }
        let rel = Compass.delta(hit.bearing, c.heading)
        let distance = max(0.1, hit.distance + Double.random(in: -0.05...0.05))
        let bearing = abs(rel) <= Self.directionHalfAngle ? rel + Double.random(in: -2...2) : nil
        smoother.push(distance: distance, bearing: bearing)
    }
}
