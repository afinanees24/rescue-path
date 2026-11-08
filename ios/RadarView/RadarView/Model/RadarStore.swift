import CoreGraphics
import Foundation
import Observation

/// Firefighter-side app state. Zero setup: on launch it scans BLE for the boards and the
/// beacon phone (…def9), swaps NI tokens over BLE, and ranges over UWB.
///
/// Direction: each valid UWB direction latches the target's absolute bearing in the gyro
/// heading frame; between directions the bearing is latch − heading, so guidance never
/// drops when the target leaves UWB's ±45° field. The dot is drawn from real NI data only.
@MainActor
@Observable
final class RadarStore {
    nonisolated static let halfAngle = 45.0      // degrees (90° wedge)
    nonisolated static let rangeSteps: [Double] = [5, 10, 20, 40]

    /// Auto-ranging: step up when the target passes 85% of the range, down below 40%.
    nonisolated static func nextRange(current: Double, distance: Double) -> Double {
        var i = rangeSteps.firstIndex(of: current) ?? 0
        while i < rangeSteps.count - 1, distance > 0.85 * rangeSteps[i] { i += 1 }
        while i > 0, distance < 0.4 * rangeSteps[i] { i -= 1 }
        return rangeSteps[i]
    }

    /// The firefighter is the origin of the world frame.
    let origin = CGPoint.zero
    let motion: MotionHeading
    let boards: BoardLink
    let guidance: GuidanceEngine
    let uwb: UWBLink
    let steps: StepTracker

    enum BearingSource: String {
        case none = "NONE"
        case uwbDirection = "UWB DIRECTION"
        case cameraAngle = "CAMERA ANGLE"
        case trilaterationAR = "TRILAT · AR"
        case trilaterationSteps = "TRILAT · STEPS"
        case gyroLatch = "GYRO LATCH"
    }

    /// Eased gyro heading the scope rotates with.
    private(set) var displayHeading: Double = 0
    private(set) var track = TrackSnapshot()
    private(set) var hasFix = false
    /// A valid UWB direction arrived in the last 0.6 s (else the dot runs on the gyro latch).
    private(set) var directionLive = false
    /// Latest distance (UWB, or RSSI estimate in FAR mode).
    private(set) var distance: Double?
    private(set) var phase: ScanPhase = .searching
    /// Scope range (m): steps 5 → 10 → 20 → 40; `displayRange` eases toward it.
    private(set) var scopeRange: Double = 5
    private(set) var displayRange: Double = 5
    /// Distance readout that counts in 0.1 m steps.
    private(set) var countedDistance: Double?
    /// Eased obstacle distance (cm) and its visibility.
    private(set) var obstacleCm: Double = 0
    private(set) var obstacleVisibility: Double = 0
    /// Where the current bearing comes from (logged on every change).
    private(set) var bearingSource: BearingSource = .none
    /// Trilateration status for [LOG].
    private(set) var trilaterationInfo = "IDLE"

    @ObservationIgnored private var latch = BearingLatch()
    @ObservationIgnored private var tracker = WorldTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var lastNIAt: Date?
    @ObservationIgnored private var lastDist: Double?
    @ObservationIgnored private var motionGeneration = 0
    @ObservationIgnored private var lastCountAt: Date = .distantPast
    @ObservationIgnored private var lastTokenRefreshAt: Date = .distantPast
    /// Ever had UWB contact this run (distinguishes SEARCHING from OUT OF RANGE).
    @ObservationIgnored private var everContact = false
    @ObservationIgnored private var lastDirectionalAt: Date?
    @ObservationIgnored private var arTrilat = Trilaterator()
    @ObservationIgnored private var stepTrilat = Trilaterator()
    @ObservationIgnored private var trilatFrame: BearingSource = .none
    @ObservationIgnored private var lastPose: (x: Double, z: Double, fx: Double, fz: Double)?
    @ObservationIgnored private var angleFlipped = false
    @ObservationIgnored private var angleVotes = (agree: 0, disagree: 0)
    /// Absolute bearing of the last real (UWB / camera) direction: the mirror hint for trilateration.
    @ObservationIgnored private var lastDirectionalAbs: Double?
    @ObservationIgnored private var cameraOnSince: Date?
    @ObservationIgnored private var cameraWasOn = false
    @ObservationIgnored private var arGeneration = 0

    init() {
        motion = MotionHeading()
        boards = BoardLink()
        guidance = GuidanceEngine(boards: boards)
        uwb = UWBLink(role: .firefighter)
        steps = StepTracker()
        // Token exchange over BLE (…def9): read the beacon's token, write ours back.
        boards.localToken = { [weak self] in self?.uwb.localToken }
        boards.onBeaconToken = { [weak self] data in self?.uwb.setPeerToken(data) }
        uwb.onLocalToken = { [weak self] _ in self?.boards.sendLocalToken() }
        uwb.onUpdate = { [weak self] in self?.niUpdate() }
        guidance.inputs = { [weak self] in self?.guidanceInputs() ?? GuidanceInputs() }
    }

    // MARK: - Derived

    var heading: Double { motion.heading }

    /// Target bearing relative to the phone's back right now (0 ahead, + right).
    var relativeBearing: Double? { latch.bearing(heading: heading) }

    var isOnTarget: Bool { phase == .onTarget }

    /// U pip: tokens exchanged and NI ranging.
    var uwbLinked: Bool { uwb.hasPeerToken && uwb.isFresh(now: Date()) }

    /// The bracelets follow the dot: same distance and latched bearing.
    private func guidanceInputs() -> GuidanceInputs {
        syncHeadingFrame()          // the guidance timer must never see a new frame with old state
        return GuidanceInputs(us: boards.currentUS(now: Date()), distance: distance,
                              bearing: hasFix ? relativeBearing : nil,
                              outOfRange: phase == .outOfRange, heading: heading,
                              usFrameTime: boards.waistUpdatedAt)
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        motion.start()
        steps.start()
        boards.start()
        uwb.start()
        guidance.start()
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
        uwb.stop()
        boards.stop()
        motion.stop()
        steps.stop()
    }

    /// [SCAN]: restart the search (keeps the last dot until new data arrives).
    func restartScan() {
        trilatFrame = .none
        arTrilat.reset()
        stepTrilat.reset()
        uwb.stop()
        boards.restartBeacon()
        uwb.start()
    }

    // MARK: - NI updates

    private func niUpdate() {
        syncHeadingFrame()
        let now = Date()
        let h = heading
        let dist = uwb.distance ?? lastDist

        // 1. UWB direction, 2. camera-assisted horizontal angle, 3. trilateration.
        var rel: Double?
        var source: BearingSource = .none
        if let dir = uwb.direction {
            let r = Double(atan2(dir.x, -dir.z)) * 180 / .pi
            rel = r
            source = .uwbDirection
            if let ha = uwb.horizontalAngle { calibrateAngleSign(ha, against: r) }
        } else if let ha = uwb.horizontalAngle {
            rel = angleFlipped ? -ha : ha
            source = .cameraAngle
        }
        // Trilateration only with a fresh NI distance, and only when no real direction lately
        // (so it never fights intermittent camera angles).
        if uwb.lastUpdateHadDistance, let d = uwb.distance { feedTrilateration(distance: d, at: now) }
        let directionRecent = lastDirectionalAt.map { now.timeIntervalSince($0) < 0.6 } ?? false
        if rel == nil, !directionRecent, let t = trilaterationBearing(heading: h) {
            rel = t.rel
            source = t.source
        }

        if let rel {
            latch.latch(heading: h, relative: rel)
            if !hasFix {
                hasFix = true
                Log.uwb(.firefighter, String(format: "direction LATCHED from %@: %+.0f° relative at %.1f m",
                                             source.rawValue, rel, dist ?? -1))
            }
            if source == .uwbDirection || source == .cameraAngle {
                lastDirectionalAt = now
                lastDirectionalAbs = wrapDegrees(h + rel)
            }
        } else if hasFix {
            source = .gyroLatch        // never clear the latch: keep steering on the gyro
        }
        if source != bearingSource {
            bearingSource = source
            Log.uwb(.firefighter, "bearing source: \(source.rawValue) at \(dist.map { String(format: "%.1f m", $0) } ?? "?")")
        }

        lastDist = dist
        lastNIAt = now
        everContact = true
        if let dist {
            tracker.ingest(distance: dist, bearing: latch.bearing(heading: h), heading: h, origin: origin, at: now)
        }
    }

    /// Heading frame changed (calibration picked another reading): rotate the latch with it
    /// (never drop it); positions and detour headings in the old frame start over.
    private func syncHeadingFrame() {
        guard motion.generation != motionGeneration else { return }
        motionGeneration = motion.generation
        latch.shift(by: motion.lastShift)
        if let a = lastDirectionalAbs { lastDirectionalAbs = wrapDegrees(a + motion.lastShift) }
        tracker.reset()
        steps.reset()
        stepTrilat.reset()
        guidance.headingFrameChanged()
    }

    /// The camera angle's sign convention isn't documented clearly: check it against UWB
    /// direction whenever both are present and flip it if they keep disagreeing.
    private func calibrateAngleSign(_ angle: Double, against direction: Double) {
        guard abs(angle) > 10, abs(direction) > 10 else { return }
        let effective = angleFlipped ? -angle : angle
        if (effective > 0) == (direction > 0) { angleVotes.agree += 1 } else { angleVotes.disagree += 1 }
        let total = angleVotes.agree + angleVotes.disagree
        guard total >= 15 else { return }
        if Double(angleVotes.disagree) / Double(total) > 0.8 {
            angleFlipped.toggle()
            Log.uwb(.firefighter, "camera angle sign flipped (disagreed with UWB direction \(angleVotes.disagree)/\(total))")
        }
        angleVotes = (0, 0)
    }

    /// Pair the NI distance with where I am: ARKit camera position while camera assist runs,
    /// otherwise step dead-reckoning along the gyro heading.
    private func feedTrilateration(distance d: Double, at now: Date) {
        if uwb.arRunning, uwb.cameraPose() == nil { return }     // brief AR hiccup: skip, keep samples
        if let pose = uwb.cameraPose() {
            if trilatFrame != .trilaterationAR || uwb.arGeneration != arGeneration {
                arGeneration = uwb.arGeneration                    // new AR session = new origin
                arTrilat.reset()
                trilatFrame = .trilaterationAR
            }
            arTrilat.add(position: .init(x: pose.x, y: pose.z), distance: d, at: now)
            lastPose = pose
            trilaterationInfo = String(format: "AR · %d SAMPLES · SPAN %.1f M", arTrilat.count, arTrilat.span)
        } else if steps.available {
            if trilatFrame != .trilaterationSteps {
                stepTrilat.reset()
                trilatFrame = .trilaterationSteps
            }
            let p = steps.position
            stepTrilat.add(position: .init(x: Double(p.x), y: Double(p.y)), distance: d, at: now)
            trilaterationInfo = String(format: "STEPS · %d SAMPLES · SPAN %.1f M", stepTrilat.count, stepTrilat.span)
        }
    }

    /// Bearing from the trilateration fix, relative to where the phone points now. With two
    /// mirror candidates (walked in a straight line), take the one nearest the latched bearing.
    private func trilaterationBearing(heading h: Double) -> (rel: Double, source: BearingSource)? {
        var rels: [Double] = []
        switch trilatFrame {
        case .trilaterationAR:
            // Only against the LIVE camera pose; a stale forward vector would latch a wrong bearing.
            guard let pose = uwb.cameraPose() else { return nil }
            for c in arTrilat.solve() {
                let vx = c.x - pose.x, vz = c.y - pose.z
                let rx = -pose.fz, rz = pose.fx              // right of forward (ARKit y up)
                rels.append(atan2(vx * rx + vz * rz, vx * pose.fx + vz * pose.fz) * 180 / .pi)
            }
        case .trilaterationSteps:
            let me = steps.position
            for c in stepTrilat.solve() {
                let abs = Compass.bearing(from: me, to: CGPoint(x: c.x, y: c.y))
                rels.append(wrapDegrees(abs - h))
            }
        default:
            return nil
        }
        guard !rels.isEmpty else { return nil }
        if rels.count == 1 { return (rels[0], trilatFrame) }
        // Mirror pair: pick the side of the last real direction (else the latch).
        guard let hint = lastDirectionalAbs.map({ wrapDegrees($0 - h) }) ?? latch.bearing(heading: h) else { return nil }
        let best = rels.min { abs(wrapDegrees($0 - hint)) < abs(wrapDegrees($1 - hint)) }!
        return (best, trilatFrame)
    }

    // MARK: - 60 Hz tick

    private func tick() {
        let now = Date()
        let dt = min(0.1, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now

        syncHeadingFrame()
        steps.tick(dt: dt, heading: heading, now: now)
        displayHeading = wrapDegrees(displayHeading + wrapDegrees(heading - displayHeading) * min(1, dt * 15))

        let live = uwb.lastDirectionAt.map { now.timeIntervalSince($0) < 0.6 } ?? false
        if live != directionLive { directionLive = live }

        // No direction hardware: camera assist stays on while the beacon is beyond 2 m (so
        // direction keeps re-latching at range) and until the first latch; within 2 m it may
        // rest, and comes back after 10 s without a direction.
        if uwb.cameraAssistSupported, uwb.hasPeerToken {
            let d = distance ?? lastDist ?? .infinity
            let beyond = uwb.cameraOn ? d > 1.8 : d > 2.0
            let starved = now.timeIntervalSince(lastDirectionalAt ?? .distantPast) > 10
            // Once on, stay on long enough to converge and refill the latch.
            let dwell = uwb.cameraOn && now.timeIntervalSince(cameraOnSince ?? now) < 5
            let feeding = uwb.cameraOn && now.timeIntervalSince(lastDirectionalAt ?? .distantPast) < 3
            let want = !hasFix || beyond || starved || dwell || feeding
            if want != uwb.cameraOn { uwb.setCameraAssist(want) }
        }
        if uwb.cameraOn != cameraWasOn {
            cameraWasOn = uwb.cameraOn
            if uwb.cameraOn {
                cameraOnSince = now
                trilatFrame = .none          // new AR session segment: AR samples start over
            }
        }

        // Token watchdog: BLE up but no NI for 4 s (or the beacon's token never arrived)
        // → re-read its token and re-write ours.
        if boards.beaconConnected, !uwb.permanentlyFailed, !uwb.isFresh(now: now, within: 4),
           now.timeIntervalSince(lastTokenRefreshAt) > 5 {
            lastTokenRefreshAt = now
            Log.uwb(.firefighter, uwb.hasPeerToken ? "no NI for 4 s with BLE up — refreshing tokens"
                                                   : "no beacon token yet — re-reading")
            boards.refreshBeaconToken()
        }

        updateState(now: now, dt: dt)
        updateCount(now: now)
        updateObstacle(now: now, dt: dt)
        boards.refreshRate(now: now)
    }

    private func updateState(now: Date, dt: Double) {
        let niFresh = lastNIAt.map { now.timeIntervalSince($0) < 2 } ?? false
        tracker.sampleTrail(now: now)
        let snap = TrackSnapshot(position: tracker.position, distance: tracker.distance(from: origin),
                                 status: tracker.status(now: now), trail: tracker.trail)
        if snap != track { track = snap }

        // Beyond UWB range: rough distance from the beacon link's RSSI while BLE is up.
        let farEstimate = (!niFresh && everContact) ? boards.beaconDistanceEstimate : nil
        let outOfRange = !niFresh && everContact && !boards.beaconConnected

        let d: Double? = niFresh ? (lastDist ?? track.distance) : farEstimate
        if d != distance { distance = d }

        // Auto-ranging scope; the drawn scale eases so the dot and trail never jump.
        if let target = d ?? track.distance {
            let next = Self.nextRange(current: scopeRange, distance: target)
            if next != scopeRange {
                scopeRange = next
                Log.uwb(.firefighter, "scope range \(Int(next)) m")
            }
        }
        if abs(displayRange - scopeRange) > 0.01 {
            displayRange += (scopeRange - displayRange) * min(1, dt * 4)
        }

        let newPhase: ScanPhase
        if !niFresh {
            newPhase = farEstimate != nil ? .far : (outOfRange ? .outOfRange : .searching)
        } else if let d, d < 1.0 {
            newPhase = .onTarget
        } else if !hasFix {
            newPhase = .searchingRanged
        } else {
            newPhase = directionLive ? .tracking : .gyro
        }
        if newPhase != phase {
            phase = newPhase
            Log.uwb(.firefighter, "state: \(newPhase.label)")
        }
    }

    /// Count the readout toward the real distance in 0.1 m steps (every 40 ms).
    private func updateCount(now: Date) {
        guard let d = distance else {
            if countedDistance != nil { countedDistance = nil }
            return
        }
        let goal = (d * 10).rounded() / 10
        guard let c = countedDistance else { countedDistance = goal; return }
        guard abs(goal - c) >= 0.05, now.timeIntervalSince(lastCountAt) >= 0.04 else { return }
        let step = abs(goal - c) > 3 ? (goal - c) / 4 : (goal > c ? 0.1 : -0.1)
        countedDistance = ((c + step) * 10).rounded() / 10
        lastCountAt = now
    }

    private func updateObstacle(now: Date, dt: Double) {
        // Red arc straight ahead only when something is within 1.5 m.
        if let us = boards.currentUS(now: now), us > 0, us < 150 {
            let cm = Double(us)
            if obstacleVisibility < 0.05 { obstacleCm = cm } else { obstacleCm += (cm - obstacleCm) * min(1, dt * 10) }
            obstacleVisibility += (1 - obstacleVisibility) * min(1, dt * 8)
        } else if obstacleVisibility > 0 {
            obstacleVisibility -= obstacleVisibility * min(1, dt * 4)
            if obstacleVisibility < 0.01 { obstacleVisibility = 0 }
        }
    }
}
