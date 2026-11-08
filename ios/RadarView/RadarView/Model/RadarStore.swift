import CoreGraphics
import Foundation
import Observation

/// App state: firefighter pose, incoming radar frames (simulated or BLE),
/// eased display values, scan blips, detections and the alert log.
@MainActor
@Observable
final class RadarStore {
    nonisolated static let range = 6.0          // meters
    nonisolated static let halfAngle = 35.0     // degrees (70° wedge)
    nonisolated static let trailLength = 7
    nonisolated static let trailInterval = 0.2
    nonisolated static let blipLifetime: TimeInterval = 30
    nonisolated static let simInterval = 0.2    // 5 Hz, same as the firmware

    let plan = FloorPlan.demoHouse
    let compass: HeadingProvider
    let ble: BLERadarClient

    private(set) var mode: DataMode = .simulated
    var firefighter = CGPoint(x: 2.5, y: 9.2)   // just outside the front door
    private(set) var useCompass = true
    var manualHeading: Double = 0
    /// Added to the compass so "map up" can be lined up with the real building.
    private(set) var northOffset: Double = 0
    var scanning = false
    var showTruth = false

    private(set) var displayHeading: Double = 0
    private(set) var moving = TrackDisplay()
    private(set) var still = TrackDisplay()
    private(set) var blips: [Blip] = []
    private(set) var detections: [TargetKind: Detection] = [:]
    private(set) var alerts: [AlertEntry] = []
    private(set) var updateRate: Double = 0
    private(set) var simTruth: [SimPerson] = []
    /// Recent eased distances per target, oldest first (newest = current position).
    private(set) var trails: [TargetKind: [Double]] = [:]

    @ObservationIgnored private let simulator: RadarSimulator
    @ObservationIgnored private var simSeeded = false
    @ObservationIgnored private var simSeedCount = 2
    @ObservationIgnored private var simWaitingSince: Date?
    @ObservationIgnored private var trailAccumulator = 0.0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var simAccumulator = 0.0
    @ObservationIgnored private var lastFrameAt: Date?
    @ObservationIgnored private var frameTimes: [Date] = []
    @ObservationIgnored private var lastBlipAt: [TargetKind: Date] = [:]
    @ObservationIgnored private var lastAlertAt: [TargetKind: Date] = [:]

    init() {
        compass = HeadingProvider()
        ble = BLERadarClient()
        simulator = RadarSimulator(plan: FloorPlan.demoHouse)
        simTruth = simulator.truth
        ble.onFrame = { [weak self] frame in self?.ingest(frame) }
    }

    // MARK: - Derived

    var compassActive: Bool { useCompass && compass.hasReading }

    var targetHeading: Double {
        compassActive ? Compass.normalize(compass.heading + northOffset) : manualHeading
    }

    /// Number of targets currently reported (0–2).
    var targetCount: Int { (moving.present ? 1 : 0) + (still.present ? 1 : 0) }

    /// The target the footer reads out: a still person always takes priority.
    var priorityKind: TargetKind? {
        if still.present { return .still }
        if moving.present { return .moving }
        return nil
    }

    func track(_ kind: TargetKind) -> TrackDisplay { kind == .still ? still : moving }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        compass.start()
        displayHeading = targetHeading
        if mode == .simulated { requestSimSeed(count: 2) }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - User actions

    func setMode(_ newMode: DataMode) {
        guard newMode != mode else { return }
        mode = newMode
        clearReading()
        if newMode == .live {
            ble.start()
        } else {
            ble.stop()
            requestSimSeed(count: 2)
        }
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

    func resetAlignment() { northOffset = 0 }

    func moveFirefighter(to p: CGPoint) {
        let b = plan.viewBounds.insetBy(dx: 0.2, dy: 0.2)
        firefighter = CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    func clearBlips() { blips.removeAll() }
    func clearAlerts() { alerts.removeAll() }

    func newScenario() {
        clearReading()
        requestSimSeed(count: Int.random(in: 1...3))
    }

    /// Place simulated people relative to where the firefighter faces. Waits briefly for
    /// the first compass reading so "ahead" means where the phone actually points.
    private func requestSimSeed(count: Int) {
        simSeeded = false
        simSeedCount = count
        simWaitingSince = Date()
    }

    private func seedSimIfReady(now: Date) {
        guard !simSeeded else { return }
        let waited = now.timeIntervalSince(simWaitingSince ?? now)
        let headingKnown = compass.hasReading || !compass.isAvailable || !useCompass
        guard headingKnown || waited > 2 else { return }
        simulator.seedAhead(origin: firefighter, heading: targetHeading, plan: plan, count: simSeedCount)
        displayHeading = targetHeading
        simTruth = simulator.truth
        simSeeded = true
    }

    // MARK: - Frame handling

    func ingest(_ frame: RadarFrame) {
        let now = Date()
        lastFrameAt = now
        frameTimes.append(now)
        moving = updated(.moving, frame.moving, moving, now: now)
        still = updated(.still, frame.still, still, now: now)
    }

    private func updated(_ kind: TargetKind, _ target: RadarTarget, _ track: TrackDisplay, now: Date) -> TrackDisplay {
        var t = track
        t.present = target.isPresent
        guard target.isPresent else { return t }
        t.target = target.meters

        // The LD2410B has no direction: the best guess is "somewhere ahead".
        let bearing = displayHeading
        let previous = detections[kind]
        detections[kind] = Detection(kind: kind, distance: target.meters, bearing: bearing,
                                     energy: target.energy, lastSeen: now)

        if scanning, now.timeIntervalSince(lastBlipAt[kind] ?? .distantPast) >= 0.25 {
            blips.append(Blip(position: firefighter.moved(bearing: bearing, distance: target.meters),
                              kind: kind, time: now))
            lastBlipAt[kind] = now
        }

        let isNew = previous.map { now.timeIntervalSince($0.lastSeen) > 3 } ?? true
        let reminderDue = kind == .still && now.timeIntervalSince(lastAlertAt[kind] ?? .distantPast) > 15
        if isNew || reminderDue {
            logAlert(kind, distance: target.meters, bearing: bearing, now: now)
        }
        return t
    }

    private func logAlert(_ kind: TargetKind, distance: Double, bearing: Double, now: Date) {
        var text = "\(kind.noun) \(String(format: "%.1f", distance)) m, bearing \(Int(Compass.normalize(bearing).rounded()) % 360)°"
        if kind == .still { text += " — possibly unconscious" }
        alerts.insert(AlertEntry(time: now, kind: kind, text: text), at: 0)
        if alerts.count > 200 { alerts.removeLast(alerts.count - 200) }
        lastAlertAt[kind] = now
    }

    private func clearReading() {
        moving = TrackDisplay()
        still = TrackDisplay()
        detections.removeAll()
        trails.removeAll()
        lastFrameAt = nil
        frameTimes.removeAll()
        updateRate = 0
    }

    // MARK: - 60 Hz tick

    private func tick() {
        let now = Date()
        let dt = min(0.1, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now

        displayHeading = Compass.normalize(
            displayHeading + Compass.delta(targetHeading, displayHeading) * min(1, dt * 8))

        if mode == .simulated {
            seedSimIfReady(now: now)
            simulator.step(dt: dt)
            if showTruth { simTruth = simulator.truth }
            simAccumulator += dt
            if simSeeded, simAccumulator >= Self.simInterval {
                simAccumulator = simAccumulator.truncatingRemainder(dividingBy: Self.simInterval)
                ingest(simulator.measure(from: firefighter, heading: displayHeading, plan: plan,
                                         halfAngle: Self.halfAngle, range: Self.range))
            }
        }

        // No data for a while (BLE dropped): fade the bands out.
        if let last = lastFrameAt, now.timeIntervalSince(last) > 1.5 {
            if moving.present { moving.present = false }
            if still.present { still.present = false }
        }
        moving = eased(moving, dt: dt)
        still = eased(still, dt: dt)

        trailAccumulator += dt
        if trailAccumulator >= Self.trailInterval {
            trailAccumulator = trailAccumulator.truncatingRemainder(dividingBy: Self.trailInterval)
            sampleTrails()
        }

        if let oldest = blips.first, now.timeIntervalSince(oldest.time) > Self.blipLifetime {
            blips.removeAll { now.timeIntervalSince($0.time) > Self.blipLifetime }
        }

        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        let rate = Double(frameTimes.count) / 2
        if abs(rate - updateRate) >= 0.25 || (rate == 0 && updateRate != 0) { updateRate = rate }
    }

    /// Remember where each marker has been so the radar can draw a fading trail.
    private func sampleTrails() {
        var next = trails
        for kind in TargetKind.allCases {
            let t = track(kind)
            var trail = next[kind] ?? []
            if t.present && t.visibility > 0.3 {
                trail.append(t.distance)
                if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
            } else if !trail.isEmpty {
                trail.removeFirst()
            }
            next[kind] = trail.isEmpty ? nil : trail
        }
        trails = next
    }

    private func eased(_ track: TrackDisplay, dt: Double) -> TrackDisplay {
        var t = track
        if t.present {
            if t.visibility < 0.05 {
                t.distance = t.target           // appear in place, don't slide in from 0
            } else {
                t.distance += (t.target - t.distance) * min(1, dt * 6)
            }
            t.visibility += (1 - t.visibility) * min(1, dt * 5)
        } else {
            t.visibility -= t.visibility * min(1, dt * 3)
            if t.visibility < 0.01 { t.visibility = 0 }
        }
        return t
    }
}
