import CoreMotion
import Foundation
import Observation

/// Heading of the phone's BACK (−z axis) from CoreMotion device motion at 50 Hz with
/// `.xArbitraryZVertical`. No Euler yaw (it gimbal-locks with the phone upright on a chest):
/// the back axis is taken from `attitude.rotationMatrix`, projected onto the horizontal plane,
/// and turned into an angle with atan2. Degrees, (−180, 180], increasing clockwise.
///
/// CoreMotion's docs don't make the matrix's direction (device→reference or the reverse)
/// unambiguous, and the wrong one makes the dot turn the wrong way. So the four candidate
/// readings (row/column × sign) are checked against the gyroscope's yaw rate about gravity
/// while you turn, and the one that matches is locked in.
@MainActor
@Observable
final class MotionHeading {
    private(set) var heading: Double = 0
    private(set) var available = false
    private(set) var calibrated = false
    private(set) var candidateName = "COLUMN +"
    /// Bumps when the heading frame changes (calibration picked another candidate).
    private(set) var generation = 0
    /// Heading jump (new − old, degrees) at the last frame change.
    private(set) var lastShift: Double = 0

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var candidate = 0
    @ObservationIgnored private var previous: [Double]?
    @ObservationIgnored private var previousTime: TimeInterval?
    @ObservationIgnored private var errors = [Double](repeating: 0, count: 4)
    @ObservationIgnored private var votes = 0
    @ObservationIgnored private var lastHeadings: [Double]?

    nonisolated static let candidateNames = headingCandidateNames

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        available = true
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.process(motion) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func process(_ m: CMDeviceMotion) {
        let r = m.attitude.rotationMatrix
        guard let headings = Self.candidates(r) else { return }    // back axis ~vertical: hold
        if !calibrated, let prev = previous, let t0 = previousTime {
            let dt = m.timestamp - t0
            if dt > 0.005 {
                // Clockwise yaw rate about the vertical = ω · ĝ (both in the device frame).
                let g = m.gravity
                let gl = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
                let w = m.rotationRate
                let yaw = gl > 0.5 ? (w.x * g.x + w.y * g.y + w.z * g.z) / gl * 180 / .pi : 0
                if abs(yaw) > 30 {
                    for i in 0..<4 {
                        let rate = wrapDegrees(headings[i] - prev[i]) / dt
                        errors[i] += (rate - yaw) * (rate - yaw)
                    }
                    votes += 1
                    if votes >= 25 { lockCalibration() }
                }
            }
        }
        previous = headings
        previousTime = m.timestamp
        lastHeadings = headings
        heading = headings[candidate]
    }

    private func lockCalibration() {
        let best = errors.indices.min { errors[$0] < errors[$1] } ?? 0
        calibrated = true
        if best != candidate {
            if let h = lastHeadings { lastShift = wrapDegrees(h[best] - h[candidate]) }
            candidate = best
            if let h = lastHeadings { heading = h[best] }
            generation += 1
        }
        candidateName = Self.candidateNames[best]
        Log.uwb(.firefighter, "heading calibrated: \(candidateName) (errors \(errors.map { Int($0 / Double(votes)) }))")
    }

    nonisolated static func candidates(_ r: CMRotationMatrix) -> [Double]? {
        backAxisHeadingCandidates(r)
    }
}
