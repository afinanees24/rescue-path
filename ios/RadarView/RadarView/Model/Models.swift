import CoreGraphics
import Foundation

enum DataMode: String, CaseIterable, Identifiable {
    case simulated, live
    var id: String { rawValue }
    var badge: String { self == .simulated ? "SIMULATED" : "LIVE" }
}

enum TargetKind: String, CaseIterable, Identifiable {
    case still, moving
    var id: String { rawValue }
    var title: String { self == .still ? "STILL" : "MOVING" }
    var noun: String { self == .still ? "Still person" : "Moving person" }
}

/// A persistent scan-mode mark: where a reading put someone, in world meters.
struct Blip: Identifiable {
    let id = UUID()
    let position: CGPoint
    let kind: TargetKind
    let time: Date
}

/// Latest reading for one target type, for the bottom sheet.
struct Detection: Identifiable {
    let kind: TargetKind
    var distance: Double
    var bearing: Double
    var energy: Int
    var lastSeen: Date
    var id: TargetKind { kind }
}

struct AlertEntry: Identifiable {
    let id = UUID()
    let time: Date
    let kind: TargetKind
    let text: String
}

/// Eased display state for one arc band, so values glide instead of jumping.
struct TrackDisplay {
    var distance: Double = 0
    var visibility: Double = 0
    var target: Double = 0
    var present = false
}

/// Ground-truth person position from the simulator (for the optional overlay).
struct SimPerson: Identifiable {
    let id: Int
    let position: CGPoint
    let isStill: Bool
}
