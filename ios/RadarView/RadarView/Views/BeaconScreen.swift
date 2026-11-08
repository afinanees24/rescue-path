import SwiftUI

/// The hidden person's phone: advertises over BLE (…def9), swaps NI tokens with the
/// firefighter and ranges. Nothing to tap.
struct BeaconScreen: View {
    let onExit: () -> Void
    @State private var link = UWBLink(role: .beacon)
    @State private var ble = BeaconPeripheral()
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
                let ranging = link.isFresh(now: tl.date) && !recent.isEmpty
                let blinkOn = ranging || tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) < 1.4
                VStack(spacing: 22) {
                    tacText("BEACON ACTIVE", 30, .heavy)
                        .foregroundStyle(Theme.teal)
                        .glow(Theme.teal, radius: 5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if ranging {
                        tacText(String(format: "CONNECTED · %.1f M", average), 24, .bold)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else {
                        tacText(waitingText, 16, .bold)
                            .foregroundStyle(Theme.ink)
                            .opacity(blinkOn ? 1 : 0.35)
                            .multilineTextAlignment(.center)
                    }
                    tacText(detailText, 11).foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            Hairline()
            VStack(spacing: 6) {
                tacText("CHEST HEIGHT OR FRONT POCKET · TOP UP · FACING THE FIREFIGHTER", 10)
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                tacText("NO KEYS OR METAL BETWEEN THE PHONES", 10).foregroundStyle(Theme.dim)
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
            link.onUpdate = {
                guard let d = link.distance else { return }
                recent.append(d)
                if recent.count > 5 { recent.removeFirst(recent.count - 5) }
            }
            link.onLocalToken = { ble.updateLocalToken($0) }
            ble.onPeerToken = { link.setPeerToken($0) }
            ble.start()
            link.start()
        }
        .onDisappear {
            link.stop()
            ble.stop()
        }
    }

    private var average: Double {
        recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
    }

    private var waitingText: String {
        link.mode == .unsupported ? "THIS IPHONE HAS NO UWB" : "WAITING FOR FIREFIGHTER"
    }

    private var detailText: String {
        if link.isFresh(now: Date()) { return "RANGING" }
        if link.hasPeerToken { return "TOKENS EXCHANGED · STARTING UWB" }
        return "BLE \(ble.state)"
    }
}
