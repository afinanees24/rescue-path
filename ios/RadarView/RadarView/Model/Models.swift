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

/// A persistent scan-mode mark: where a reading put the target, in world meters.
struct Blip: Identifiable {
    let id = UUID()
    let position: CGPoint
    let time: Date
}

/// Eased display state for the target, so the marker glides instead of jumping.
struct TargetDisplay {
    var distance: Double = 0
    var bearing: Double = 0
    /// 1 while there is a distance, fading to 0 when it's lost.
    var visibility: Double = 0
    /// 1 while there is a bearing; fades to 0 when direction is nil (dot → ring).
    var bearingVisibility: Double = 0
    var present = false
}

/// One past marker position (relative bearing, distance) for the fading trail.
struct TrailPoint {
    let bearing: Double
    let distance: Double
}

/// Ground-truth person position from the simulator (for the optional overlay).
struct SimPerson: Identifiable {
    let id: Int
    let position: CGPoint
    let isStill: Bool
}
