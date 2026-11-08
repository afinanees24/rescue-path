import CoreGraphics
import CoreMotion
import Foundation
import Observation

/// Step dead-reckoning for the trilateration fallback when ARKit isn't running:
/// CMPedometer gives walking speed (pace / distance deltas); the position advances along
/// the gyro heading (phone on the chest, back facing forward = walking direction).
/// Coordinates are meters in the gyro heading frame (same convention as `CGPoint.moved`).
@MainActor
@Observable
final class StepTracker {
    private(set) var available = false
    private(set) var position = CGPoint.zero
    /// Total walked distance reported by the pedometer this run (m).
    private(set) var walked: Double = 0
    private(set) var speed: Double = 0

    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var lastDistance: Double?
    @ObservationIgnored private var lastUpdateAt: Date?

    func start() {
        guard CMPedometer.isDistanceAvailable() || CMPedometer.isStepCountingAvailable() else { return }
        available = true
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let data else { return }
            let distance = data.distance?.doubleValue
            let pace = data.currentPace?.doubleValue
            Task { @MainActor in self?.received(distance: distance, pace: pace) }
        }
    }

    func stop() {
        pedometer.stopUpdates()
    }

    /// Start a fresh frame (e.g. after the heading frame changed).
    func reset() {
        position = .zero
    }

    /// Advance the position along `heading` (degrees) at the current walking speed.
    func tick(dt: Double, heading: Double, now: Date) {
        if let t = lastUpdateAt, now.timeIntervalSince(t) > 3 { speed = 0 }   // stopped walking
        guard speed > 0.15 else { return }
        position = position.moved(bearing: heading, distance: speed * dt)
    }

    private func received(distance: Double?, pace: Double?) {
        let now = Date()
        if let pace, pace > 0 {
            speed = min(2.5, 1 / pace)
        } else if let d = distance, let last = lastDistance, let t = lastUpdateAt {
            let dt = now.timeIntervalSince(t)
            if dt > 0.2 { speed = min(2.5, max(0, (d - last) / dt)) }
        }
        if let d = distance {
            walked = d
            lastDistance = d
        }
        lastUpdateAt = now
    }
}
