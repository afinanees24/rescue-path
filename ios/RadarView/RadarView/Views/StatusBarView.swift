import SwiftUI

/// Top strip: data source badge (tap to switch), BLE state, update rate, heading.
struct StatusBarView: View {
    let store: RadarStore

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.setMode(store.mode == .simulated ? .live : .simulated)
            } label: {
                Text(store.mode.badge)
                    .font(Theme.mono(15, .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(store.mode == .simulated ? Theme.sim : Theme.live,
                                in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Data source \(store.mode.badge)")
            .accessibilityHint("Switches between simulated and live radar data")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(bleColor).frame(width: 10, height: 10)
                    Text(bleText).lineLimit(1)
                }
                Text(String(format: "%.1f Hz", store.updateRate))
                    .foregroundStyle(store.updateRate > 0 ? Theme.text : Theme.dim)
            }
            .font(Theme.mono(13, .semibold))
            .foregroundStyle(Theme.text)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Compass.label(store.displayHeading))
                    .font(Theme.mono(24, .heavy))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.identity)
                Text(headingSource)
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(store.compassActive ? Theme.radar : Theme.sim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var headingSource: String {
        if store.compassActive { return "COMPASS" }
        return store.compass.isAvailable ? "MANUAL" : "MANUAL · NO COMPASS"
    }

    private var bleText: String {
        guard store.mode == .live else { return "BLE off (sim)" }
        let s = store.ble.state
        if s == .connected, let name = store.ble.connectedName { return "\(name) connected" }
        return s.label
    }

    private var bleColor: Color {
        guard store.mode == .live else { return Theme.dim }
        switch store.ble.state {
        case .connected: return Theme.live
        case .scanning, .connecting, .reconnecting: return Theme.sim
        default: return Theme.still
        }
    }
}
