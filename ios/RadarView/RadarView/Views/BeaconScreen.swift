import SwiftUI

/// The hidden person's phone: joins the UWB session and shows that it's active.
struct BeaconScreen: View {
    let onExit: () -> Void
    @State private var link = UWBLink(role: .beacon)
    @State private var recent: [Double] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    tacText("FF-RADAR", 14, .bold).foregroundStyle(Theme.ink)
                    tacText("BEACON", 11).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button(action: onExit) {
                    tacText("[EXIT]", 13, .bold).foregroundStyle(Theme.line)
                        .frame(minWidth: 88, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            Hairline()

            Spacer()

            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                let ranging = link.isFresh(now: tl.date)
                let on = !ranging || tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) < 1.4
                VStack(spacing: 22) {
                    tacText("BEACON", 40, .heavy)
                        .foregroundStyle(ranging ? Theme.cyan : Theme.ink)
                        .glow(ranging ? Theme.cyan : .clear, radius: 5)
                    tacText("ACTIVE", 40, .heavy)
                        .foregroundStyle(ranging ? Theme.cyan : Theme.ink)
                        .glow(ranging ? Theme.cyan : .clear, radius: 5)
                        .opacity(on ? 1 : 0.3)
                    Text(distanceText(ranging))
                        .font(.system(size: 64, weight: .medium, design: .monospaced))
                        .foregroundStyle(ranging ? Theme.ink : Theme.dim)
                        .padding(.top, 10)
                    tacText(statusText, 12).foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            Hairline()
            VStack(spacing: 6) {
                tacText("HOLD AT CHEST HEIGHT · SCREEN OUT", 11).foregroundStyle(Theme.dim)
                if let err = link.lastError {
                    tacText(err.uppercased(), 10).foregroundStyle(Theme.red).multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .background(Color.black.ignoresSafeArea())
        .overlay { Scanlines().ignoresSafeArea() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            link.onSample = { d, _ in
                guard let d else { return }
                recent.append(d)
                if recent.count > 5 { recent.removeFirst(recent.count - 5) }
            }
            link.start()
        }
        .onDisappear { link.stop() }
    }

    private func distanceText(_ ranging: Bool) -> String {
        guard ranging, !recent.isEmpty else { return "--" }
        return String(format: "%.1fm", recent.reduce(0, +) / Double(recent.count))
    }

    private var statusText: String {
        switch link.status {
        case .ranging: "RANGING · \(link.peerName ?? "FIREFIGHTER")"
        case .connected: "LINKED · \(link.peerName ?? "FIREFIGHTER") · WAITING FOR UWB"
        case .searching: "WAITING FOR FIREFIGHTER"
        case .unsupported: "THIS IPHONE HAS NO UWB"
        case .idle: "STARTING"
        }
    }
}
