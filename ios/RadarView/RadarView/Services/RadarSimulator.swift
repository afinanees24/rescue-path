import CoreGraphics
import Foundation

/// Fake people in the demo house, for the SIM target source.
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

    /// The hidden person for UWB-style simulation: one person roughly along `heading`,
    /// walking slowly toward and away from the firefighter between 0.8 and 5 m.
    func seedBeacon(origin: CGPoint, heading: Double) {
        let motion = Motion.radial(origin: origin, bearing: heading, near: 0.8, far: 5.0,
                                   period: Double.random(in: 18...24),
                                   phase: Double.random(in: 0..<(2 * .pi)))
        people = [Person(id: 0, position: origin, motion: motion)]
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

    /// Distance and world bearing to the nearest person.
    func nearest(from origin: CGPoint) -> (distance: Double, bearing: Double)? {
        people
            .map { (distance: origin.distance(to: $0.position), bearing: Compass.bearing(from: origin, to: $0.position)) }
            .min { $0.distance < $1.distance }
    }
}
