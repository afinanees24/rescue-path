import Foundation

/// What each wrist feels, built from the bracelet firmware's 2-byte commands.
///
/// The firmware ignores byte 1 for FORWARD (there is no start delay), so the left→right
/// ripple is made by the app: every 300 ms a short [1,0] burst on L, the same on R 150 ms
/// later, each ended with [0,0].
enum HapticPattern: Equatable {
    case off, stop, forwardRipple
    case left(UInt8), right(UInt8)

    /// The ripple is 6 steps of the 50 ms tick: L on for steps 0–1, R on for steps 3–4
    /// (100 ms bursts, 150 ms stagger, 300 ms period). Rounding to whole steps tolerates
    /// ±25 ms of timer jitter; comparing times directly would make burst lengths uneven.
    nonisolated static let rippleStep: TimeInterval = 0.05

    var isRipple: Bool { self == .forwardRipple }

    /// What the footer shows: exactly what's being sent.
    var label: String {
        switch self {
        case .off: "OFF"
        case .stop: "STOP"
        case .forwardRipple: "FORWARD"
        case .left(let i): "TURN LEFT \(i)"
        case .right(let i): "TURN RIGHT \(i)"
        }
    }

    /// Bracelets this pattern actually drives.
    var activeSides: [Side] {
        switch self {
        case .off: []
        case .stop, .forwardRipple: [.left, .right]
        case .left: [.left]
        case .right: [.right]
        }
    }

    /// Command for each bracelet. `t` is the time since the ripple started (ignored otherwise).
    func commands(rippleElapsed t: TimeInterval) -> [Side: BraceletCommand] {
        switch self {
        case .off: return [.left: .off, .right: .off]
        case .stop: return [.left: .stop, .right: .stop]
        case .left(let i): return [.left: .turn(i), .right: .off]
        case .right(let i): return [.right: .turn(i), .left: .off]
        case .forwardRipple:
            let step = Int((max(0, t) / Self.rippleStep).rounded()) % 6
            let leftOn = step == 0 || step == 1
            let rightOn = step == 3 || step == 4
            return [.left: leftOn ? .forward : .off, .right: rightOn ? .forward : .off]
        }
    }
}

/// Buttons in the [LOG] haptics test panel.
enum HapticTest: String, CaseIterable, Identifiable {
    case forward = "FORWARD", left = "LEFT", right = "RIGHT", stop = "STOP", off = "OFF"
    var id: String { rawValue }

    func pattern(intensity: UInt8) -> HapticPattern {
        switch self {
        case .forward: .forwardRipple
        case .left: .left(intensity)
        case .right: .right(intensity)
        case .stop: .stop
        case .off: .off
        }
    }
}
