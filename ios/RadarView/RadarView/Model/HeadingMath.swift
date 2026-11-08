import CoreMotion
import Foundation

let headingCandidateNames = ["COLUMN +", "COLUMN −", "ROW +", "ROW −"]

/// Heading (degrees, clockwise, (−180, 180]) of the phone's back (−z) axis projected onto the
/// horizontal plane, for the four ways of reading CoreMotion's rotation matrix
/// (third column or third row, either sign). nil if the back axis is near vertical.
func backAxisHeadingCandidates(_ r: CMRotationMatrix) -> [Double]? {
    let col = (x: r.m13, y: r.m23), row = (x: r.m31, y: r.m32)
    func heading(_ v: (x: Double, y: Double)) -> Double? {
        let bx = -v.x, by = -v.y                 // back = −z
        guard (bx * bx + by * by).squareRoot() > 0.25 else { return nil }
        return atan2(bx, by) * 180 / .pi         // clockwise from reference +y
    }
    guard let hc = heading(col), let hr = heading(row) else { return nil }
    return [wrapDegrees(hc), wrapDegrees(-hc), wrapDegrees(hr), wrapDegrees(-hr)]
}
