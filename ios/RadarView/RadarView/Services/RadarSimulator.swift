import CoreGraphics
import Foundation

/// Fake people. Produces frames in the same shape as the ESP32 JSON:
/// like the LD2410B, it only knows distance, and only for people inside the cone.
final class RadarSimulator {
    private enum Motion {
        case still(anchor: CGPoint)
        case wander(area: CGRect, heading: Double, speed: Double)
        /// Walks toward and away from `origin` along a bearing, between `near` and `far` meters.
        case radial(origin: CGPoint, bearing: Double, near: Double, far: Double, period: Double, phase: Double)
    }

    private struct Person {
        let id: Int
        var position: CGPoint
        var motion: Motion
        var isStill: Bool {
            if case .still = motion { return true }
            return false
        }
    }

    private var people: [Person] = []
    private var time: Double = 0

    init(plan: FloorPlan, count: Int = 3) {
        reset(plan: plan, count: count)
    }

    var truth: [SimPerson] {
        people.map { SimPerson(id: $0.id, position: $0.position, isStill: $0.isStill) }
    }

    /// Room scenario: one person lies still in Bedroom 2; the rest wander inside other rooms.
    func reset(plan: FloorPlan, count: Int) {
        func area(_ name: String) -> CGRect {
            (plan.room(named: name)?.rect ?? plan.viewBounds).insetBy(dx: 0.5, dy: 0.5)
        }
        let stillSpot = CGPoint(x: 8.4, y: 1.6)
        var list = [Person(id: 0, position: stillSpot, motion: .still(anchor: stillSpot))]
        let moverRooms = ["Living", "Bedroom 1", "Kitchen"].shuffled()
        for i in 0..<max(0, min(count, 3) - 1) {
            list.append(wanderer(id: i + 1, in: area(moverRooms[i])))
        }
        people = list
    }

    /// Demo scenario relative to where the firefighter stands and faces: a still person
    /// roughly ahead at ~3 m, a moving person drifting between 1.5 and 5 m slightly off
    /// centre, and (for count 3) someone wandering in the living room.
    func seedAhead(origin: CGPoint, heading: Double, plan: FloorPlan, count: Int = 2) {
        let stillSpot = origin.moved(bearing: heading + Double.random(in: -8...8),
                                     distance: Double.random(in: 2.8...3.2))
        var list = [Person(id: 0, position: stillSpot, motion: .still(anchor: stillSpot))]
        if count >= 2 {
            let side: Double = Bool.random() ? 1 : -1
            let motion = Motion.radial(origin: origin, bearing: heading + side * Double.random(in: 10...18),
                                       near: 1.5, far: 5.0, period: Double.random(in: 12...16),
                                       phase: Double.random(in: 0..<(2 * .pi)))
            list.append(Person(id: 1, position: origin, motion: motion))
        }
        if count >= 3, let living = plan.room(named: "Living") {
            list.append(wanderer(id: 2, in: living.rect.insetBy(dx: 0.5, dy: 0.5)))
        }
        people = list
        step(dt: 0)
    }

    private func wanderer(id: Int, in r: CGRect) -> Person {
        let start = CGPoint(x: Double.random(in: r.minX...r.maxX), y: Double.random(in: r.minY...r.maxY))
        return Person(id: id, position: start,
                      motion: .wander(area: r, heading: Double.random(in: 0..<360),
                                      speed: Double.random(in: 0.4...0.8)))
    }

    func step(dt: Double) {
        time += dt
        for i in people.indices {
            var p = people[i]
            switch p.motion {
            case .still(let anchor):
                // Breathing: a couple of centimetres of chest movement.
                p.position = CGPoint(x: anchor.x + 0.02 * sin(time * 1.6), y: anchor.y)

            case .wander(let area, var heading, let speed):
                heading = Compass.normalize(heading + Double.random(in: -60...60) * dt)
                let next = p.position.moved(bearing: heading, distance: speed * dt)
                if area.contains(next) {
                    p.position = next
                } else {
                    heading = Compass.normalize(heading + 180 + Double.random(in: -50...50))
                }
                p.motion = .wander(area: area, heading: heading, speed: speed)

            case .radial(let origin, let bearing, let near, let far, let period, let phase):
                let s = 0.5 - 0.5 * cos(2 * .pi * time / period + phase)      // 0…1
                let wobble = 4 * sin(time * 0.7 + phase)                         // a few degrees of drift
                p.position = origin.moved(bearing: bearing + wobble, distance: near + (far - near) * s)
            }
            people[i] = p
        }
    }

    /// Nearest moving person and nearest still person inside the cone, with sensor jitter.
    func measure(from origin: CGPoint, heading: Double, plan: FloorPlan,
                 halfAngle: Double, range: Double) -> RadarFrame {
        var nearest: [Bool: (dist: Double, walls: Int)] = [:]
        for p in people {
            let d = origin.distance(to: p.position)
            guard d <= range, d > 0.2 else { continue }
            let b = Compass.bearing(from: origin, to: p.position)
            guard abs(Compass.delta(b, heading)) <= halfAngle else { continue }
            if let current = nearest[p.isStill], current.dist <= d { continue }
            nearest[p.isStill] = (d, plan.wallsCrossed(from: origin, to: p.position))
        }

        func target(still: Bool) -> RadarTarget {
            guard let hit = nearest[still] else { return RadarTarget() }
            let dist = max(0.3, hit.dist + Double.random(in: -0.12...0.12))
            let base = still ? 75.0 : 95.0
            let energy = base - dist * 8 - Double(hit.walls) * 9 + Double.random(in: -6...6)
            return RadarTarget(dist: Int((dist * 100).rounded()),
                               energy: Int(min(100, max(5, energy))))
        }
        return RadarFrame(moving: target(still: false), still: target(still: true))
    }
}
