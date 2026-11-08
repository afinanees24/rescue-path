import SwiftUI

/// Monochrome tactical-handheld palette: black screen, thin off-white lines,
/// light-blue ping, teal-green target, red only for danger (STOP / close obstacle).
enum Theme {
    static let ink = Color(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255)
    static let line = ink.opacity(0.7)
    static let grid = ink.opacity(0.65)
    static let faint = ink.opacity(0.22)
    static let dim = ink.opacity(0.45)
    static let text = ink
    /// Ping band (#7FC8FF).
    static let ping = Color(red: 0x7F / 255, green: 0xC8 / 255, blue: 1)
    /// Target marker, aligned state, ON TARGET (#4CFFB0).
    static let teal = Color(red: 0x4C / 255, green: 1, blue: 0xB0 / 255)
    /// Connection pips and live states.
    static let cyan = Color(red: 0x5F / 255, green: 0xE3 / 255, blue: 1)
    static let red = Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)

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
    /// Soft phosphor glow.
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
            ctx.fill(p, with: .color(.black.opacity(0.22)))
        }
        .overlay(
            RadialGradient(colors: [.clear, .black.opacity(0.3)], center: .center,
                           startRadius: 220, endRadius: 650)
        )
        .allowsHitTesting(false)
    }
}
