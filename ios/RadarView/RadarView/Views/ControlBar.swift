import SwiftUI

/// Big glove-friendly buttons under the map.
struct ControlBar: View {
    let store: RadarStore

    var body: some View {
        HStack(spacing: 10) {
            BigButton(title: store.scanning ? "STOP SCAN" : "SCAN",
                      systemImage: store.scanning ? "stop.fill" : "dot.radiowaves.left.and.right",
                      tint: store.scanning ? Theme.still : Theme.radar,
                      filled: store.scanning) {
                store.scanning.toggle()
            }

            if store.compassActive {
                BigButton(title: "COMPASS", systemImage: "location.north.line.fill",
                          tint: Theme.radar, filled: false) {
                    store.setUseCompass(false)
                }
                .frame(maxWidth: 130)
            } else {
                IconButton(systemImage: "rotate.left") { store.rotateManual(by: -15) }
                IconButton(systemImage: "rotate.right") { store.rotateManual(by: 15) }
                if store.compass.isAvailable {
                    IconButton(systemImage: "location.north.line") { store.setUseCompass(true) }
                        .accessibilityLabel("Use compass")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct BigButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.mono(18, .heavy))
                .frame(maxWidth: .infinity, minHeight: 60)
                .foregroundStyle(filled ? Color.black : tint)
                .background(filled ? tint : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .bold))
                .frame(width: 60, height: 60)
                .foregroundStyle(Theme.sim)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.sim, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
