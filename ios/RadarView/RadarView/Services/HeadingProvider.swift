import CoreLocation
import Observation

/// Phone compass heading via CoreLocation. Falls back to magnetic heading when
/// true heading is unavailable.
@MainActor
@Observable
final class HeadingProvider: NSObject {
    private(set) var heading: Double = 0
    private(set) var hasReading = false
    let isAvailable = CLLocationManager.headingAvailable()

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
        manager.headingOrientation = .portrait
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        guard isAvailable else { return }
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingHeading()
    }

    private func update(_ value: Double) {
        heading = value
        hasReading = true
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        // Location lets CoreLocation correct to true north; heading works without it.
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}

extension HeadingProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard value >= 0 else { return }
        MainActor.assumeIsolated { self.update(value) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
