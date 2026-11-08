import SwiftUI

/// Monochrome tactical-handheld palette: black screen, thin off-white lines,
/// cyan for live signals, red only for a still person.
enum Theme {
    static let ink = Color(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255)
    static let line = ink.opacity(0.7)
    static let faint = ink.opacity(0.22)
    static let cyan = Color(red: 0x5F / 255, green: 0xE3 / 255, blue: 1)
    static let red = Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)

    static let background = Color.black
    static let panel = Color.black
    static let panelRaised = Color.white.opacity(0.06)
    static let roomFill = Color.white.opacity(0.035)
    static let grid = Color.white.opacity(0.04)
    static let wall = line
    static let text = ink
    static let dim = ink.opacity(0.45)

    // Roles used by the floor-plan (MAP) view.
    static let radar = cyan
    static let moving = cyan
    static let still = red
    static let firefighter = ink
    static let sim = ink
    static let live = cyan

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Small, wide-tracked monospaced device text.
func tacText(_ string: String, _ size: CGFloat = 12, _ weight: Font.Weight = .medium) -> Text {
    Text(string)
        .font(.system(size: size, weight: weight, design: .monospaced))
        .tracking(size * 0.2)
}

/// 1 pt divider line.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

extension View {
    /// Soft phosphor glow for cyan/red elements.
    func glow(_ color: Color, radius: CGFloat = 4) -> some View {
        shadow(color: color.opacity(0.9), radius: radius)
            .shadow(color: color.opacity(0.45), radius: radius * 2)
    }
}

/// Very faint scanlines plus a light vignette, like a low-res device screen.
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var y: CGFloat = 0
            while y < size.height {
                p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            ctx.fill(p, with: .color(.black.opacity(0.3)))
        }
        .overlay(
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center,
                           startRadius: 220, endRadius: 650)
        )
        .allowsHitTesting(false)
    }
}
