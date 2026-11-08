import CoreGraphics
import Foundation
import Observation

/// Firefighter-side app state: boards (BLE), the selected target source, the guidance
/// engine, compass heading, eased display values, scan blips and the marker trail.
@MainActor
@Observable
final class RadarStore {
    nonisolated static let range = 5.0           // meters shown on the scope
    nonisolated static let halfAngle = 45.0      // degrees (90° wedge, UWB's direction field)
    nonisolated static let trailLength = 7
    nonisolated static let trailInterval = 0.2
    nonisolated static let blipLifetime: TimeInterval = 30

    let plan = FloorPlan.demoHouse
    let compass: HeadingProvider
    let boards: BoardLink
    let guidance: GuidanceEngine
    let uwb: UWBLink

    private(set) var sourceKind: SourceKind = .uwb
    var firefighter = CGPoint(x: 2.5, y: 9.2)   // just outside the front door
    private(set) var useCompass = true
    var manualHeading: Double = 0
    /// Added to the compass so "map up" can be lined up with the real building.
    private(set) var northOffset: Double = 0
    var scanning = false
    var showTruth = false

    private(set) var displayHeading: Double = 0
    /// Smoothed values the rules use.
    private(set) var fix: TargetFix = .none
    private(set) var sourceActive = false
    /// Eased values for drawing.
    private(set) var target = TargetDisplay()
    private(set) var trail: [TrailPoint] = []
    private(set) var blips: [Blip] = []
    private(set) var simTruth: [SimPerson] = []
    /// Eased obstacle distance (cm) and its visibility.
    private(set) var obstacleCm: Double = 0
    private(set) var obstacleVisibility: Double = 0

    @ObservationIgnored private var sources: [SourceKind: TargetSource] = [:]
    @ObservationIgnored private let simSource: SimTargetSource
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var trailAccumulator = 0.0
    @ObservationIgnored private var lastBlipAt: Date = .distantPast

    init() {
        compass = HeadingProvider()
        boards = BoardLink()
        guidance = GuidanceEngine(boards: boards)
        uwb = UWBLink(role: .firefighter)
        let sim = SimTargetSource(plan: FloorPlan.demoHouse)
        simSource = sim
        sources = [
            .uwb: UWBTargetSource(link: uwb),
            .radar: RadarTargetSource(boards: boards),
            .sim: sim,
        ]
        guidance.inputs = { [weak self] in
            self?.guidanceInputs() ?? GuidanceInputs(sourceActive: false)
        }
    }

    // MARK: - Derived

    private var source: TargetSource { sources[sourceKind]! }

    /// False for the radar source: distance only, target drawn on the centre line.
    var providesBearing: Bool { source.providesBearing }

    var compassActive: Bool { useCompass && compass.hasReading }

    var targetHeading: Double {
        compassActive ? Compass.normalize(compass.heading + northOffset) : manualHeading
    }

    private func guidanceInputs() -> GuidanceInputs {
        GuidanceInputs(us: boards.currentUS(now: Date()), distance: fix.distance,
                       bearing: fix.bearing, sourceActive: sourceActive)
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        compass.start()
        boards.start()
        guidance.start()
        source.start()
        displayHeading = targetHeading
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        guidance.stop()
        source.stop()
        boards.stop()
    }

    // MARK: - User actions

    func setSource(_ kind: SourceKind) {
        guard kind != sourceKind else { return }
        source.stop()
        sourceKind = kind
        resetTarget()
        if timer != nil { source.start() }
    }

    func setUseCompass(_ on: Bool) {
        if !on { manualHeading = displayHeading }
        useCompass = on
    }

    func rotateManual(by degrees: Double) {
        if useCompass { setUseCompass(false) }
        manualHeading = Compass.normalize(manualHeading + degrees)
    }

    /// Make the direction the phone currently faces become "map up".
    func alignMapToFacing() {
        guard compass.hasReading else { return }
        northOffset = Compass.normalize(-compass.heading)
        useCompass = true
    }

    func moveFirefighter(to p: CGPoint) {
        let b = plan.viewBounds.insetBy(dx: 0.2, dy: 0.2)
        firefighter = CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    func clearBlips() { blips.removeAll() }

    /// New simulated person somewhere within ±60° of where the phone points.
    func newScenario() {
        simSource.reseed(randomize: true)
        resetTarget()
    }

    private func resetTarget() {
        fix = .none
        target = TargetDisplay()
        trail.removeAll()
        sourceActive = false
    }

    // MARK: - 60 Hz tick

    private func tick() {
        let now = Date()
        let dt = min(0.1, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now

        displayHeading = Compass.normalize(
            displayHeading + Compass.delta(targetHeading, displayHeading) * min(1, dt * 8))

        let headingReady = compass.hasReading || !compass.isAvailable || !useCompass
        source.tick(SourceContext(now: now, dt: dt, firefighter: firefighter,
                                  heading: displayHeading, headingReady: headingReady))
        let newFix = source.fix
        if newFix != fix { fix = newFix }
        let active = source.isActive
        if active != sourceActive { sourceActive = active }
        if sourceKind == .sim, showTruth { simTruth = simSource.truth }

        target = eased(target, dt: dt)
        updateObstacle(now: now, dt: dt)
        recordBlip(now: now)

        trailAccumulator += dt
        if trailAccumulator >= Self.trailInterval {
            trailAccumulator = trailAccumulator.truncatingRemainder(dividingBy: Self.trailInterval)
            sampleTrail()
        }

        if let oldest = blips.first, now.timeIntervalSince(oldest.time) > Self.blipLifetime {
            blips.removeAll { now.timeIntervalSince($0.time) > Self.blipLifetime }
        }

        boards.refreshRate(now: now)
    }

    private func eased(_ track: TargetDisplay, dt: Double) -> TargetDisplay {
        var t = track
        if let d = fix.distance {
            if t.visibility < 0.05 { t.distance = d } else { t.distance += (d - t.distance) * min(1, dt * 6) }
            t.visibility += (1 - t.visibility) * min(1, dt * 5)
            t.present = true
        } else {
            t.visibility -= t.visibility * min(1, dt * 3)
            if t.visibility < 0.01 { t.visibility = 0 }
            t.present = false
        }
        if let b = fix.bearing {
            if t.bearingVisibility < 0.05 { t.bearing = b } else { t.bearing += (b - t.bearing) * min(1, dt * 6) }
            t.bearingVisibility += (1 - t.bearingVisibility) * min(1, dt * 5)
        } else {
            // Direction lost: the dot fades out where it was, leaving the range ring.
            t.bearingVisibility -= t.bearingVisibility * min(1, dt * 2)
            if t.bearingVisibility < 0.01 { t.bearingVisibility = 0 }
        }
        return t
    }

    private func updateObstacle(now: Date, dt: Double) {
        if let us = boards.currentUS(now: now), us > 0 {
            let cm = Double(us)
            if obstacleVisibility < 0.05 { obstacleCm = cm } else { obstacleCm += (cm - obstacleCm) * min(1, dt * 10) }
            obstacleVisibility += (1 - obstacleVisibility) * min(1, dt * 8)
        } else if obstacleVisibility > 0 {
            obstacleVisibility -= obstacleVisibility * min(1, dt * 4)
            if obstacleVisibility < 0.01 { obstacleVisibility = 0 }
        }
    }

    /// SCAN: leave a world-fixed dot for each reading (throttled to 4/s).
    private func recordBlip(now: Date) {
        guard scanning, let d = fix.distance, now.timeIntervalSince(lastBlipAt) >= 0.25 else { return }
        let rel: Double
        if let b = fix.bearing { rel = b } else if !providesBearing { rel = 0 } else { return }
        blips.append(Blip(position: firefighter.moved(bearing: displayHeading + rel, distance: d), time: now))
        lastBlipAt = now
    }

    /// Remember where the marker has been so the scope can draw a fading trail.
    private func sampleTrail() {
        let showsDot = providesBearing ? target.bearingVisibility > 0.5 : true
        if target.present, target.visibility > 0.3, showsDot {
            trail.append(TrailPoint(bearing: providesBearing ? target.bearing : 0, distance: target.distance))
            if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
        } else if !trail.isEmpty {
            trail.removeFirst()
        }
    }
}
