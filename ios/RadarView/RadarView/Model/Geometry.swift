import CoreGraphics
import Foundation

/// Compass math. Bearings are degrees clockwise from map-up (north), 0..<360.
/// World coordinates are meters with +x to the right and +y down the screen.
enum Compass {
    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Smallest signed difference `a - b`, in (-180, 180].
    static func delta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Unit vector pointing along a bearing, in screen-style coordinates (y down).
    static func unit(_ bearing: Double) -> CGVector {
        let r = bearing * .pi / 180
        return CGVector(dx: sin(r), dy: -cos(r))
    }

    static func bearing(from a: CGPoint, to b: CGPoint) -> Double {
        normalize(atan2(Double(b.x - a.x), Double(a.y - b.y)) * 180 / .pi)
    }

    /// "087°"
    static func label(_ bearing: Double) -> String {
        String(format: "%03d°", Int(normalize(bearing).rounded()) % 360)
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> Double {
        hypot(Double(p.x - x), Double(p.y - y))
    }

    func moved(bearing: Double, distance: Double) -> CGPoint {
        let u = Compass.unit(bearing)
        return CGPoint(x: x + u.dx * distance, y: y + u.dy * distance)
    }
}
