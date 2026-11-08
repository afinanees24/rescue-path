import Foundation

/// One LD2410B target as sent by the ESP32: distance in cm (0 = none), energy 0–100.
struct RadarTarget: Decodable, Equatable {
    var dist: Int
    var energy: Int

    init(dist: Int = 0, energy: Int = 0) {
        self.dist = dist
        self.energy = energy
    }

    var isPresent: Bool { dist > 0 }
    var meters: Double { Double(dist) / 100 }

    private enum CodingKeys: String, CodingKey { case dist, energy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept ints or floats; missing fields count as 0.
        let d = (try? c.decodeIfPresent(Double.self, forKey: .dist)) ?? 0
        let e = (try? c.decodeIfPresent(Double.self, forKey: .energy)) ?? 0
        dist = max(0, Int(d.rounded()))
        energy = min(100, max(0, Int(e.rounded())))
    }
}

/// `{"moving":{"dist":210,"energy":64},"still":{"dist":340,"energy":41}}`
struct RadarFrame: Decodable, Equatable {
    var moving: RadarTarget
    var still: RadarTarget

    init(moving: RadarTarget = RadarTarget(), still: RadarTarget = RadarTarget()) {
        self.moving = moving
        self.still = still
    }

    static let empty = RadarFrame()

    private enum CodingKeys: String, CodingKey { case moving, still }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moving = (try? c.decodeIfPresent(RadarTarget.self, forKey: .moving)) ?? RadarTarget()
        still = (try? c.decodeIfPresent(RadarTarget.self, forKey: .still)) ?? RadarTarget()
    }

    static func parse(_ data: Data) -> RadarFrame? {
        try? JSONDecoder().decode(RadarFrame.self, from: data)
    }
}
