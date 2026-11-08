import CoreGraphics
import Foundation

/// What the tracker currently knows about the target.
enum TrackStatus: Equatable {
    /// No readings at all.
    case none
    /// Fresh readings with direction: the dot is exact.
    case tracking
    /// Fresh distance but no direction lately: dot held at its last known bearing.
    case lastKnown
    /// Distance but never a direction yet: only a range is known.
    case rangeOnly
    /// No readings for a while.
    case searching
}

/// Turns UWB readings (distance + bearing relative to the phone) into a steady target
/// position in WORLD coordinates (meters, same frame as the floor plan), so turning your
/// body rotates the dot around you instead of moving it.
///
/// - world bearing = compass heading + UWB bearing
/// - adaptive exponential moving average on world x/y: slow for jitter under 30 cm (steady),
///   fast for real moves (follows a 1 m step in ~0.4 s)
/// - a reading more than 1.5 m from the filtered position is ignored, unless 3 in a row
///   agree (then the target really moved, and the filter jumps to it)
/// - with no direction, the dot stays on its last known bearing and slides to the new distance
struct WorldTracker {
    /// Filter time constant for small jitter (steady) and for real moves (responsive).
    var steadyTimeConstant: TimeInterval = 0.3
    var moveTimeConstant: TimeInterval = 0.12
    /// Deviations smaller than this are treated as jitter.
    var jitterRadius = 0.3
    var outlierJump = 1.5
    var outlierLimit = 3
    var directionHold: TimeInterval = 0.6
    var staleAfter: TimeInterval = 1.5
    /// ~1.5 s of trail at one dot per 0.15 s.
    var trailLength = 10
    var trailInterval: TimeInterval = 0.15

    private(set) var position: CGPoint?
    private(set) var rangeOnlyDistance: Double?
    /// Recent filtered positions, oldest first.
    private(set) var trail: [CGPoint] = []
    private(set) var rejected = 0

    private var lastAccepted: Date?
    private var lastReading: Date?
    private var lastDirection: Date?
    private var lastTrailAt: Date = .distantPast
    private var outlierStreak = 0

    mutating func reset() {
        self = WorldTracker(steadyTimeConstant: steadyTimeConstant, moveTimeConstant: moveTimeConstant,
                            jitterRadius: jitterRadius, outlierJump: outlierJump, outlierLimit: outlierLimit,
                            directionHold: directionHold, staleAfter: staleAfter,
                            trailLength: trailLength, trailInterval: trailInterval)
    }

    /// Feed one reading. `bearing` is relative to the phone (0 ahead, + right); `heading` is
    /// the compass heading when it was taken; `origin` is the firefighter's world position.
    mutating func ingest(distance: Double, bearing: Double?, heading: Double, origin: CGPoint, at now: Date) {
        lastReading = now
        let measured: CGPoint
        if let b = bearing {
            measured = origin.moved(bearing: heading + b, distance: distance)
            lastDirection = now
        } else if let p = position {
            // No direction: keep the last known world bearing, update the distance.
            measured = origin.moved(bearing: Compass.bearing(from: origin, to: p), distance: distance)
        } else {
            rangeOnlyDistance = smooth(rangeOnlyDistance, distance, now: now)
            lastAccepted = now
            return
        }

        guard let p = position else {
            position = measured
            lastAccepted = now
            outlierStreak = 0
            return
        }

        if p.distance(to: measured) > outlierJump {
            outlierStreak += 1
            rejected += 1
            guard outlierStreak >= outlierLimit else { return }
            position = measured                     // consistent jump: the target really moved
            outlierStreak = 0
            lastAccepted = now
            return
        }

        outlierStreak = 0
        let tau = p.distance(to: measured) < jitterRadius ? steadyTimeConstant : moveTimeConstant
        let a = alpha(now: now, timeConstant: tau)
        position = CGPoint(x: p.x + (measured.x - p.x) * a, y: p.y + (measured.y - p.y) * a)
        lastAccepted = now
    }

    func status(now: Date) -> TrackStatus {
        guard let last = lastReading else { return position == nil ? .none : .searching }
        if now.timeIntervalSince(last) > staleAfter { return .searching }
        if position == nil { return .rangeOnly }
        if let d = lastDirection, now.timeIntervalSince(d) <= directionHold { return .tracking }
        return .lastKnown
    }

    /// Distance from the firefighter to the filtered target.
    func distance(from origin: CGPoint) -> Double? {
        position.map { origin.distance(to: $0) } ?? rangeOnlyDistance
    }

    /// Record the filtered position for the dotted trail (call every tick).
    mutating func sampleTrail(now: Date) {
        guard let p = position, now.timeIntervalSince(lastTrailAt) >= trailInterval else { return }
        lastTrailAt = now
        if let last = trail.last, last.distance(to: p) < 0.02 { return }   // standing still: no new dot
        trail.append(p)
        if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
    }

    private func alpha(now: Date, timeConstant: TimeInterval) -> Double {
        let dt = min(0.5, max(0.01, now.timeIntervalSince(lastAccepted ?? now)))
        return 1 - exp(-dt / timeConstant)
    }

    private func smooth(_ current: Double?, _ value: Double, now: Date) -> Double {
        guard let c = current else { return value }
        let tau = abs(value - c) < jitterRadius ? steadyTimeConstant : moveTimeConstant
        return c + (value - c) * alpha(now: now, timeConstant: tau)
    }
}
