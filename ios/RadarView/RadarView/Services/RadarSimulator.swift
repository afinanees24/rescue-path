import CoreGraphics
import Foundation

/// Fake people in the demo house. Produces frames in the same shape as the ESP32 JSON:
/// like the LD2410B, it only knows distance, and only for people inside the cone.
final class RadarSimulator {
    private struct Person {
        let id: Int
        var position: CGPoint
        let isStill: Bool
        let area: CGRect
        var heading: Double
        var speed: Double
        let anchor: CGPoint
    }

    private var people: [Person] = []
    private var time: Double = 0

    init(plan: FloorPlan, count: Int = 3) {
        reset(plan: plan, count: count)
    }

    var truth: [SimPerson] {
        people.map { SimPerson(id: $0.id, position: $0.position, isStill: $0.isStill) }
    }

    /// One person always lies still in Bedroom 2; the rest wander inside other rooms.
    func reset(plan: FloorPlan, count: Int) {
        func area(_ name: String) -> CGRect {
            (plan.room(named: name)?.rect ?? plan.viewBounds).insetBy(dx: 0.5, dy: 0.5)
        }
        let stillSpot = CGPoint(x: 8.4, y: 1.6)
        var list = [Person(id: 0, position: stillSpot, isStill: true, area: area("Bedroom 2"),
                           heading: 0, speed: 0, anchor: stillSpot)]
        let moverRooms = ["Living", "Bedroom 1", "Kitchen"].shuffled()
        for i in 0..<max(0, min(count, 3) - 1) {
            let r = area(moverRooms[i])
            let start = CGPoint(x: Double.random(in: r.minX...r.maxX), y: Double.random(in: r.minY...r.maxY))
            list.append(Person(id: i + 1, position: start, isStill: false, area: r,
                               heading: Double.random(in: 0..<360),
                               speed: Double.random(in: 0.4...0.8), anchor: start))
        }
        people = list
    }

    func step(dt: Double) {
        time += dt
        for i in people.indices {
            var p = people[i]
            if p.isStill {
                // Breathing: a couple of centimetres of chest movement.
                p.position = CGPoint(x: p.anchor.x + 0.02 * sin(time * 1.6), y: p.anchor.y)
            } else {
                p.heading = Compass.normalize(p.heading + Double.random(in: -60...60) * dt)
                let next = p.position.moved(bearing: p.heading, distance: p.speed * dt)
                if p.area.contains(next) {
                    p.position = next
                } else {
                    p.heading = Compass.normalize(p.heading + 180 + Double.random(in: -50...50))
                }
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
