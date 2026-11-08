import CoreGraphics
import Foundation
import Observation

/// Firefighter-side app state: boards (BLE), the selected target source, the guidance
/// engine, compass heading, the world-coordinate target tracker and SCAN dots.
@MainActor
@Observable
final class RadarStore {
    nonisolated static let range = 5.0           // meters shown on the scope
    nonisolated static let halfAngle = 45.0      // degrees (90° wedge)
    nonisolated static let blipLifetime: TimeInterval = 30

    /// The firefighter is the origin of the world frame.
    let origin = CGPoint.zero
    let compass: HeadingProvider
    let boards: BoardLink
    let guidance: GuidanceEngine
    let uwb: UWBLink

    private(set) var sourceKind: SourceKind = .uwb
    private(set) var scanning = false

    /// Eased compass heading the scope rotates with.
    private(set) var displayHeading: Double = 0
    /// Smoothed values the guidance rules use.
    private(set) var fix: TargetFix = .none
    private(set) var sourceActive = false
    /// Steady world-coordinate target (UWB / SIM).
    private(set) var track = TrackSnapshot()
    /// Radar source: distance only.
    private(set) var range = RangeDisplay()
    /// Distance readout that counts in 0.1 m steps.
    private(set) var countedDistance: Double?
    private(set) var blips: [Blip] = []
    /// Eased obstacle distance (cm) and its visibility.
    private(set) var obstacleCm: Double = 0
    private(set) var obstacleVisibility: Double = 0

    @ObservationIgnored private var sources: [SourceKind: TargetSource] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var tracker = WorldTracker()
    @ObservationIgnored private var lastReadingTime: Date?
    @ObservationIgnored private var lastBlipAt: Date = .distantPast
    @ObservationIgnored private var lastCountAt: Date = .distantPast

    init() {
        compass = HeadingProvider()
        boards = BoardLink()
        guidance = GuidanceEngine(boards: boards)
        uwb = UWBLink(role: .firefighter)
        sources = [
            .uwb: UWBTargetSource(link: uwb),
            .radar: RadarTargetSource(boards: boards),
            .sim: SimTargetSource(),
        ]
        guidance.inputs = { [weak self] in
            self?.guidanceInputs() ?? GuidanceInputs(sourceActive: false)
        }
    }

    // MARK: - Derived

    private var source: TargetSource { sources[sourceKind]! }

    /// False for the radar source: distance only, target drawn on the centre line.
    var providesBearing: Bool { source.providesBearing }

    /// Live compass heading (0 until the compass reports).
    var heading: Double { compass.hasReading ? compass.heading : 0 }

    /// Target bearing relative to where the phone points now (0 ahead, + right).
    var relativeBearing: Double? {
        guard providesBearing, let p = track.position else { return providesBearing ? nil : (range.present ? 0 : nil) }
        return Compass.delta(Compass.bearing(from: origin, to: p), displayHeading)
    }

    /// Exact distance to show (before the 0.1 m counting).
    var shownDistance: Double? {
        providesBearing ? track.distance : (range.present ? range.distance : nil)
    }

    /// Tracking status for the screen, for any source.
    var status: TrackStatus {
        if providesBearing { return track.status }
        return range.present ? .tracking : (sourceActive ? .searching : .none)
    }

    var isOnTarget: Bool {
        guard let d = shownDistance else { return false }
        return d < 1.0 && (status == .tracking || status == .lastKnown)
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
        displayHeading = heading
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

    /// [SRC]: UWB → RADAR → SIM → UWB.
    func cycleSource() {
        source.stop()
        sourceKind = sourceKind.next
        resetTarget()
        if timer != nil { source.start() }
    }

    /// [SCAN]: start leaving dots; tap again to stop and clear them.
    func toggleScan() {
        if scanning {
            scanning = false
            blips.removeAll()
        } else {
            scanning = true
        }
    }

    private func resetTarget() {
        fix = .none
        range = RangeDisplay()
        tracker.reset()
        track = TrackSnapshot()
        countedDistance = nil
        lastReadingTime = nil
        sourceActive = false
    }

    // MARK: - 60 Hz tick

    private func tick() {
        let now = Date()
        let dt = min(0.1, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now

        let h = heading
        displayHeading = Compass.normalize(displayHeading + Compass.delta(h, displayHeading) * min(1, dt * 8))

        source.tick(SourceContext(now: now, dt: dt, firefighter: origin, heading: h,
                                  headingReady: compass.hasReading || !compass.isAvailable))
        let newFix = source.fix
        if newFix != fix { fix = newFix }
        let active = source.isActive
        if active != sourceActive { sourceActive = active }

        updateTrack(now: now, heading: h)
        updateRange(dt: dt)
        updateCount(now: now)
        updateObstacle(now: now, dt: dt)

        if let oldest = blips.first, now.timeIntervalSince(oldest.time) > Self.blipLifetime {
            blips.removeAll { now.timeIntervalSince($0.time) > Self.blipLifetime }
        }
        boards.refreshRate(now: now)
    }

    /// Feed each new raw reading into the world tracker (and SCAN), publish the result.
    private func updateTrack(now: Date, heading h: Double) {
        if let r = source.latestReading, r.time != lastReadingTime {
            lastReadingTime = r.time
            tracker.ingest(distance: r.distance, bearing: r.bearing, heading: h, origin: origin, at: r.time)
            if scanning, let b = r.bearing, now.timeIntervalSince(lastBlipAt) >= 0.2 {
                blips.append(Blip(position: origin.moved(bearing: h + b, distance: r.distance), time: now))
                lastBlipAt = now
            }
        }
        tracker.sampleTrail(now: now)
        let snap = TrackSnapshot(position: tracker.position, distance: tracker.distance(from: origin),
                                 status: tracker.status(now: now), trail: tracker.trail)
        if snap != track { track = snap }
    }

    /// Radar source: ease the distance-only reading; SCAN dots go on the centre line.
    private func updateRange(dt: Double) {
        guard !providesBearing else { return }
        var r = range
        if let d = fix.distance {
            if r.visibility < 0.05 { r.distance = d } else { r.distance += (d - r.distance) * min(1, dt * 6) }
            r.visibility += (1 - r.visibility) * min(1, dt * 5)
            r.present = true
            if scanning, Date().timeIntervalSince(lastBlipAt) >= 0.2 {
                blips.append(Blip(position: origin.moved(bearing: heading, distance: d), time: Date()))
                lastBlipAt = Date()
            }
        } else {
            r.visibility -= r.visibility * min(1, dt * 3)
            if r.visibility < 0.01 { r.visibility = 0 }
            r.present = false
        }
        if r != range { range = r }
    }

    /// Count the readout toward the real distance in 0.1 m steps (every 40 ms).
    private func updateCount(now: Date) {
        guard let d = shownDistance else {
            if countedDistance != nil { countedDistance = nil }
            return
        }
        let goal = (d * 10).rounded() / 10
        guard let c = countedDistance else { countedDistance = goal; return }
        guard abs(goal - c) >= 0.05, now.timeIntervalSince(lastCountAt) >= 0.04 else { return }
        countedDistance = ((c + (goal > c ? 0.1 : -0.1)) * 10).rounded() / 10
        lastCountAt = now
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
}
