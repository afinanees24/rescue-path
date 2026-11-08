import SwiftUI

enum Theme {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.05)
    static let panel = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let panelRaised = Color(red: 0.13, green: 0.14, blue: 0.17)
    static let roomFill = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let grid = Color.white.opacity(0.05)
    static let wall = Color(white: 0.88)
    static let text = Color.white
    static let dim = Color(white: 0.62)

    static let radar = Color(red: 0.20, green: 1.00, blue: 0.55)
    static let moving = Color(red: 1.00, green: 0.55, blue: 0.00)
    static let still = Color(red: 1.00, green: 0.17, blue: 0.22)
    static let firefighter = Color(red: 0.25, green: 0.70, blue: 1.00)
    static let sim = Color(red: 1.00, green: 0.78, blue: 0.10)
    static let live = Color(red: 0.20, green: 1.00, blue: 0.55)

    static func color(for kind: TargetKind) -> Color {
        kind == .still ? still : moving
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
