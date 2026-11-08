import Foundation

/// Wrap degrees to (−180, 180].
func wrapDegrees(_ d: Double) -> Double {
    var a = d.truncatingRemainder(dividingBy: 360)
    if a > 180 { a -= 360 }
    if a <= -180 { a += 360 }
    return a
}

/// Holds the target's ABSOLUTE bearing (in the gyro heading frame) once a valid UWB
/// direction has been seen. Every valid direction re-latches it (5-sample average on
/// sin/cos), so gyro drift never accumulates. In between, the relative bearing is just
/// absTarget − heading, valid even when UWB direction is nil.
struct BearingLatch {
    private var sines: [Double] = []
    private var cosines: [Double] = []
    private(set) var absTarget: Double?

    var hasFix: Bool { absTarget != nil }

    mutating func reset() {
        sines.removeAll()
        cosines.removeAll()
        absTarget = nil
    }

    /// `relative`: UWB direction, degrees (+ right). `heading`: gyro heading, degrees.
    mutating func latch(heading: Double, relative: Double) {
        let a = wrapDegrees(heading + relative) * .pi / 180
        sines.append(sin(a))
        cosines.append(cos(a))
        if sines.count > 5 {
            sines.removeFirst(sines.count - 5)
            cosines.removeFirst(cosines.count - 5)
        }
        let s = sines.reduce(0, +), c = cosines.reduce(0, +)
        absTarget = atan2(s, c) * 180 / .pi
    }

    /// The heading frame rotated by `delta` degrees (heading calibration switched readings):
    /// move the latch with it so the relative bearing is preserved.
    mutating func shift(by delta: Double) {
        guard let a = absTarget else { return }
        let r = delta * .pi / 180
        for i in sines.indices {
            let ang = atan2(sines[i], cosines[i]) + r
            sines[i] = sin(ang)
            cosines[i] = cos(ang)
        }
        absTarget = wrapDegrees(a + delta)
    }

    /// Bearing relative to where the phone's back points now (0 ahead, + right).
    func bearing(heading: Double) -> Double? {
        absTarget.map { wrapDegrees($0 - heading) }
    }
}
