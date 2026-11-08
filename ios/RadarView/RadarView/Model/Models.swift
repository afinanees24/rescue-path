import CoreGraphics
import Foundation

/// Where the target (the person being searched for) comes from.
enum SourceKind: String, CaseIterable, Identifiable {
    case uwb, radar, sim
    var id: String { rawValue }
    var label: String {
        switch self {
        case .uwb: "UWB"
        case .radar: "RADAR"
        case .sim: "SIM"
        }
    }
    /// [SRC] cycles UWB → RADAR → SIM → UWB.
    var next: SourceKind {
        switch self {
        case .uwb: .radar
        case .radar: .sim
        case .sim: .uwb
        }
    }
}

/// Smoothed target measurement. Bearing: degrees, 0 = ahead, + right, − left.
struct TargetFix: Equatable {
    var distance: Double?
    var bearing: Double?
    static let none = TargetFix()
}

/// 5-sample moving average on distance and bearing (keeps the bracelets from flickering).
/// A value is nil when most of the recent samples didn't measure it.
struct FixSmoother {
    let window: Int
    private var samples: [(distance: Double?, bearing: Double?)] = []

    init(window: Int = 5) { self.window = window }

    mutating func push(distance: Double?, bearing: Double?) {
        samples.append((distance, bearing))
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    mutating func reset() { samples.removeAll() }

    var fix: TargetFix {
        guard !samples.isEmpty else { return .none }
        func average(_ values: [Double?]) -> Double? {
            let measured = values.compactMap { $0 }
            guard measured.count * 2 > values.count else { return nil }
            return measured.reduce(0, +) / Double(measured.count)
        }
        return TargetFix(distance: average(samples.map(\.distance)),
                         bearing: average(samples.map(\.bearing)))
    }
}

/// One raw measurement from a target source (before smoothing).
struct TargetReading: Equatable {
    let distance: Double
    /// Relative to the phone: 0 ahead, + right, − left. nil = no direction.
    let bearing: Double?
    let time: Date
}

/// The tracked target in world coordinates, for drawing.
struct TrackSnapshot: Equatable {
    var position: CGPoint?
    var distance: Double?
    var status: TrackStatus = .none
    var trail: [CGPoint] = []
}

/// Eased distance for the radar source (distance only, drawn on the centre line).
struct RangeDisplay: Equatable {
    var distance: Double = 0
    var visibility: Double = 0
    var present = false
}

/// A SCAN mark: where one reading put the target, in world meters.
struct Blip: Identifiable {
    let id = UUID()
    let position: CGPoint
    let time: Date
}
