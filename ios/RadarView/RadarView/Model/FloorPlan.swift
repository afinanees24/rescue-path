import CoreGraphics

struct Room: Identifiable {
    let id: String
    let rect: CGRect
    var name: String { id }
}

struct Wall {
    let a: CGPoint
    let b: CGPoint
}

/// A top-down floor plan in meters.
struct FloorPlan {
    let rooms: [Room]
    let walls: [Wall]
    /// The area of the world the map shows (house plus a margin outside).
    let viewBounds: CGRect

    func room(named name: String) -> Room? {
        rooms.first { $0.id == name }
    }

    /// Number of walls the straight line p→q passes through.
    func wallsCrossed(from p: CGPoint, to q: CGPoint) -> Int {
        walls.filter { Self.segmentsIntersect(p, q, $0.a, $0.b) }.count
    }

    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// A 10 m × 8 m single-storey house with five rooms. The front door is on the bottom wall.
    ///
    ///  0 ┌──────────┬─────┬─────────┐
    ///    │ Bedroom 1│Bath │Bedroom 2│
    ///  4 ├─  ───────┴─  ──┴───  ────┤
    ///    │  Living        │ Kitchen │
    ///    │               (door)     │
    ///  8 └──  ──────────────────────┘
    ///    0  2 3            6        10
    static let demoHouse: FloorPlan = {
        func w(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Wall {
            Wall(a: CGPoint(x: x1, y: y1), b: CGPoint(x: x2, y: y2))
        }
        let walls: [Wall] = [
            // Outside walls (front door gap at x 2–3 on the bottom wall)
            w(0, 0, 10, 0), w(0, 0, 0, 8), w(10, 0, 10, 8),
            w(0, 8, 2, 8), w(3, 8, 10, 8),
            // Hall wall at y = 4 with doors into Bedroom 1, Bath, Bedroom 2
            w(0, 4, 1.5, 4), w(2.5, 4, 4.8, 4), w(5.6, 4, 7.5, 4), w(8.5, 4, 10, 4),
            // Bedroom / bath dividers
            w(4, 0, 4, 4), w(6.5, 0, 6.5, 4),
            // Living / kitchen divider with a doorway
            w(6, 4, 6, 5.5), w(6, 6.8, 6, 8),
        ]
        let rooms = [
            Room(id: "Bedroom 1", rect: CGRect(x: 0, y: 0, width: 4, height: 4)),
            Room(id: "Bath", rect: CGRect(x: 4, y: 0, width: 2.5, height: 4)),
            Room(id: "Bedroom 2", rect: CGRect(x: 6.5, y: 0, width: 3.5, height: 4)),
            Room(id: "Living", rect: CGRect(x: 0, y: 4, width: 6, height: 4)),
            Room(id: "Kitchen", rect: CGRect(x: 6, y: 4, width: 4, height: 4)),
        ]
        return FloorPlan(rooms: rooms, walls: walls,
                         viewBounds: CGRect(x: -1, y: -1, width: 12, height: 12))
    }()
}
