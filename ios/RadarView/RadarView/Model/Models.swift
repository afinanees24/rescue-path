import CoreGraphics
import Foundation

/// The tracked target in world coordinates (gyro heading frame), for drawing.
struct TrackSnapshot: Equatable {
    var position: CGPoint?
    var distance: Double?
    var status: TrackStatus = .none
    var trail: [CGPoint] = []
}

/// Where the firefighter's search is, shown in the header.
enum ScanPhase: Equatable {
    /// No UWB distance yet.
    case searching
    /// UWB distance, but no valid direction has latched yet.
    case searchingRanged
    /// Dot placed; UWB direction currently valid.
    case tracking
    /// Dot placed from the latch; direction currently nil (running on the gyro).
    case gyro
    /// No UWB for 2 s but the BLE link is up: rough distance from RSSI.
    case far
    /// No UWB and no BLE.
    case outOfRange
    /// Under 1 m.
    case onTarget

    var label: String {
        switch self {
        case .searching, .searchingRanged: "SEARCHING"
        case .tracking: "TRACKING"
        case .gyro: "TRACKING · GYRO"
        case .far: "FAR · BLE"
        case .outOfRange: "OUT OF RANGE"
        case .onTarget: "ON TARGET"
        }
    }
}
