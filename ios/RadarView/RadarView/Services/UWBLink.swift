import ARKit
import Foundation
import NearbyInteraction
import Observation

enum AppRole: String {
    case firefighter, beacon
}

/// The Nearby Interaction session on either phone. Tokens travel over BLE (…def9):
/// `onLocalToken` hands this phone's archived token to the BLE side whenever a new session
/// creates one; `setPeerToken` runs the session with the other phone's token.
///
/// On the firefighter phone, if the hardware has no direction measurement, camera
/// assistance (with a shared ARSession) can be switched on and off by the store: on until
/// the first valid direction latches, off while running on the gyro latch.
/// Invalidation / suspension / timeout recover by themselves.
@MainActor
@Observable
final class UWBLink: NSObject {
    enum Mode: String {
        case off = "OFF"
        case unsupported = "NO UWB"
        case uwbOnly = "UWB-ONLY"
        case cameraAssist = "CAMERA-ASSIST"
        case gyro = "GYRO"
    }

    let role: AppRole
    let deviceModel = UWBLink.machineName()

    private(set) var mode: Mode = .off
    /// Archived token of the current NI session.
    private(set) var localToken: Data?
    private(set) var hasPeerToken = false
    private(set) var distance: Double?
    private(set) var direction: SIMD3<Float>?
    /// Camera-assisted azimuth (degrees, as reported; sign verified by the store).
    private(set) var horizontalAngle: Double?
    /// Farthest distance at which a direction (UWB or camera angle) arrived this run.
    private(set) var maxDirectionDistance: Double = 0
    private(set) var lastUpdate: Date?
    private(set) var lastDirectionAt: Date?
    private(set) var supportsDirection = false
    private(set) var cameraAssistSupported = false
    private(set) var cameraOn = false
    private(set) var convergence = ""
    private(set) var arTracking = "OFF"
    private(set) var lastError: String?
    private(set) var updateCount = 0
    /// The latest NI update carried a distance (vs. a held previous value).
    private(set) var lastUpdateHadDistance = false

    /// NI refused for good (permission denied / unsupported): don't keep re-exchanging tokens.
    private(set) var permanentlyFailed = false
    /// Bumps whenever a new ARSession starts (new world origin).
    private(set) var arGeneration = 0

    /// Our own AR session is running for camera assistance (pose may still be briefly unavailable).
    var arRunning: Bool { cameraOn && useOwnAR && ar != nil }

    @ObservationIgnored var onLocalToken: (@MainActor (Data) -> Void)?
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    @ObservationIgnored private var ni: NISession?
    @ObservationIgnored private var ar: ARSession?
    @ObservationIgnored private var peerToken: NIDiscoveryToken?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var useOwnAR = true
    @ObservationIgnored private var arErrorCount = 0
    @ObservationIgnored private var restartScheduled = false
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var tokenRetries = 0
    @ObservationIgnored private var lastSummaryAt: Date = .distantPast

    init(role: AppRole) {
        self.role = role
        super.init()
    }

    /// True if an NI update arrived in the last `seconds`.
    func isFresh(now: Date, within seconds: TimeInterval = 2) -> Bool {
        guard let t = lastUpdate else { return false }
        return now.timeIntervalSince(t) < seconds
    }

    // MARK: - Start / stop

    func start() {
        guard !running else { return }
        running = true
        lastError = nil
        permanentlyFailed = false
        let caps = NISession.deviceCapabilities
        supportsDirection = caps.supportsDirectionMeasurement
        cameraAssistSupported = role == .firefighter && !supportsDirection && caps.supportsCameraAssistance
        log("start: model=\(deviceModel) preciseDistance=\(caps.supportsPreciseDistanceMeasurement) "
            + "direction=\(caps.supportsDirectionMeasurement) cameraAssist=\(caps.supportsCameraAssistance)")
        guard caps.supportsPreciseDistanceMeasurement else {
            mode = .unsupported
            lastError = "This iPhone has no UWB chip"
            log("STOP: no UWB")
            return
        }
        useOwnAR = true
        arErrorCount = 0
        tokenRetries = 0
        if role == .firefighter, cameraAssistSupported {
            startAR()
            cameraOn = true
            mode = .cameraAssist
        } else {
            mode = supportsDirection || role == .beacon ? .uwbOnly : .gyro
        }
        makeSession()
    }

    func stop() {
        log("stop")
        running = false
        restartTask?.cancel()
        restartTask = nil
        ni?.invalidate()
        ni = nil
        ar?.pause()
        ar = nil
        arTracking = "OFF"
        cameraOn = false
        peerToken = nil
        hasPeerToken = false
        localToken = nil
        restartScheduled = false
        distance = nil
        direction = nil
        lastUpdate = nil
        if mode != .unsupported { mode = .off }
    }

    /// Run the session with the other phone's archived token. Returns false if it can't be read.
    @discardableResult
    func setPeerToken(_ data: Data) -> Bool {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            lastError = "Bad token from peer"
            log("ERROR peer token (\(data.count) bytes) could not be decoded")
            return false
        }
        log("peer token received (\(data.count) bytes)")
        peerToken = token
        hasPeerToken = true
        run()
        return true
    }

    /// Firefighter, no direction hardware: camera assistance on until direction latches.
    func setCameraAssist(_ on: Bool) {
        guard role == .firefighter, cameraAssistSupported, on != cameraOn, running else { return }
        cameraOn = on
        mode = on ? .cameraAssist : .gyro
        if on {
            if useOwnAR { resumeAR() }
            log("camera assist ON")
        } else {
            ar?.pause()
            arTracking = useOwnAR ? "PAUSED" : arTracking
            log("camera assist OFF (latched, within 2 m) — running on gyro")
        }
        run()
    }

    // MARK: - Session

    private func startAR() {
        guard ARWorldTrackingConfiguration.isSupported else {
            useOwnAR = false
            log("ARKit world tracking unsupported; NI runs camera assist internally")
            return
        }
        let session = ARSession()
        ar = session
        arGeneration += 1
        resumeAR()
        log("AR session started")
    }

    private func resumeAR() {
        guard let ar else { return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity            // required by Nearby Interaction
        config.isCollaborationEnabled = false
        config.userFaceTrackingEnabled = false
        config.initialWorldMap = nil
        ar.run(config)
        arTracking = "STARTING"
    }

    private func makeSession() {
        let s = NISession()
        s.delegate = self
        s.delegateQueue = .main
        if cameraAssistSupported, useOwnAR, let ar { s.setARSession(ar) }
        ni = s
        guard let token = s.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            tokenRetries += 1
            log("NISession created, own token MISSING — retry \(tokenRetries)")
            scheduleRestart(after: min(3, 0.5 * Double(tokenRetries)))
            return
        }
        tokenRetries = 0
        localToken = data
        log("NISession created, token \(data.count) bytes")
        onLocalToken?(data)
        if peerToken != nil { run() }
    }

    private func run() {
        guard let ni, let peerToken else { return }
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        config.isCameraAssistanceEnabled = cameraOn
        ni.run(config)
        log("NI run (camera assist \(cameraOn ? "on" : "off"))")
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard !restartScheduled else { return }
        restartScheduled = true
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.restartScheduled = false
            guard self.running else { return }
            self.ni?.invalidate()
            self.makeSession()
        }
    }

    // MARK: - Delegate handlers

    /// Horizontal camera pose in the AR world (x, z) and its forward direction, when our own
    /// AR session is running and tracking normally.
    func cameraPose() -> (x: Double, z: Double, fx: Double, fz: Double)? {
        guard cameraOn, useOwnAR, let frame = ar?.currentFrame, case .normal = frame.camera.trackingState else { return nil }
        let m = frame.camera.transform
        let fx = Double(-m.columns.2.x), fz = Double(-m.columns.2.z)
        let len = (fx * fx + fz * fz).squareRoot()
        guard len > 0.3 else { return nil }
        return (Double(m.columns.3.x), Double(m.columns.3.z), fx / len, fz / len)
    }

    private func update(distance d: Float?, direction dir: SIMD3<Float>?, horizontalAngle h: Float?) {
        let now = Date()
        if let d { distance = Double(d) }
        lastUpdateHadDistance = d != nil
        failures = 0
        direction = dir
        horizontalAngle = h.map { Double($0) * 180 / .pi }
        if dir != nil || h != nil {
            lastDirectionAt = now
            if let dist = distance, dist > maxDirectionDistance { maxDirectionDistance = dist }
        }
        lastUpdate = now
        arErrorCount = 0
        updateCount += 1
        if let frame = ar?.currentFrame, cameraOn {
            let t = Self.trackingLabel(frame.camera.trackingState)
            if t != arTracking { arTracking = t }
        }
        // Every NI update: distance, direction / horizontal angle, convergence, mode.
        let ds = d.map { String(format: "%.2f", $0) } ?? "nil"
        let rel = dir.map { String(format: "%+.0f", Double(atan2($0.x, -$0.z)) * 180 / .pi) } ?? "nil"
        let ha = horizontalAngle.map { String(format: "%+.0f", $0) } ?? "nil"
        log("NI #\(updateCount) d=\(ds) dir=\(rel) hAngle=\(ha) conv=\(convergence.isEmpty ? "-" : convergence) mode=\(mode.rawValue)")
        onUpdate?()
    }

    private func removed(timeout: Bool) {
        log("NI removed peer (\(timeout ? "timeout, re-running" : "peer ended"))")
        if timeout { run() }
    }

    private func invalidated(_ message: String, arProblem: Bool, permanent: Bool) {
        lastError = message
        ni = nil
        localToken = nil
        guard running else { return }
        if permanent {
            // Permission denied / unsupported: retrying only floods BLE with new tokens.
            permanentlyFailed = true
            ar?.pause()
            cameraOn = false
            mode = .off
            log("ERROR NI invalidated: \(message) — not retrying (check Nearby Interaction permission)")
            return
        }
        failures += 1
        if arProblem {
            arErrorCount += 1
            if arErrorCount >= 2, useOwnAR {
                useOwnAR = false
                ar?.pause()
                ar = nil
                arTracking = "NI INTERNAL"
                log("ERROR NI invalidated: \(message) ×\(arErrorCount) — NI runs camera assist internally now")
            } else {
                log("ERROR NI invalidated: \(message) — retrying")
            }
        } else {
            log("ERROR NI invalidated: \(message) — new session")
        }
        scheduleRestart(after: min(8, (arProblem ? 1.0 : 0.5) * pow(2, Double(max(0, failures - 1)))))
    }

    private func setConvergence(_ text: String) {
        if text != convergence { log("camera-assist convergence: \(text)") }
        convergence = text
    }

    nonisolated private func log(_ message: String) { Log.uwb(role, message) }

    // MARK: - Helpers

    nonisolated static func machineName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    nonisolated static func trackingLabel(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: "NORMAL"
        case .notAvailable: "NOT AVAILABLE"
        case .limited(let reason):
            switch reason {
            case .initializing: "INITIALIZING"
            case .excessiveMotion: "TOO FAST"
            case .insufficientFeatures: "LOW DETAIL"
            case .relocalizing: "RELOCALIZING"
            @unknown default: "LIMITED"
            }
        }
    }

    nonisolated static func reasonName(_ r: NIAlgorithmConvergenceStatus.Reason) -> String {
        switch r {
        case .insufficientLighting: "NOT ENOUGH LIGHT"
        case .insufficientMovement: "NOT ENOUGH MOVEMENT"
        case .insufficientHorizontalSweep: "NEEDS SIDE-TO-SIDE SWEEP"
        case .insufficientVerticalSweep: "NEEDS UP-DOWN SWEEP"
        default: (r.localizedDescription ?? "UNKNOWN").uppercased()
        }
    }
}

extension UWBLink: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let obj = nearbyObjects.first else { return }
        let d = obj.distance
        let dir = obj.direction
        let h = obj.horizontalAngle
        MainActor.assumeIsolated {
            guard session === self.ni else { return }        // stale session
            self.update(distance: d, direction: dir, horizontalAngle: h)
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                             reason: NINearbyObject.RemovalReason) {
        let timeout = reason == .timeout
        MainActor.assumeIsolated {
            guard session === self.ni else { return }
            self.removed(timeout: timeout)
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        log("NI suspended")
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        log("NI suspension ended, re-running")
        MainActor.assumeIsolated { self.run() }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let message = error.localizedDescription
        let code = (error as? NIError)?.code
        let arProblem = code == .invalidARConfiguration || message.uppercased().contains("AR_SESSION")
        let permanent = code == .userDidNotAllow || code == .unsupportedPlatform
        MainActor.assumeIsolated {
            guard session === self.ni else { return }
            self.invalidated(message, arProblem: arProblem, permanent: permanent)
        }
    }

    nonisolated func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence,
                             for object: NINearbyObject?) {
        let text: String
        switch convergence.status {
        case .converged: text = "CONVERGED"
        case .notConverged(let reasons):
            text = reasons.isEmpty ? "NOT CONVERGED" : reasons.map(Self.reasonName).joined(separator: ", ")
        case .unknown: text = "UNKNOWN"
        @unknown default: text = ""
        }
        MainActor.assumeIsolated { self.setConvergence(text) }
    }
}
