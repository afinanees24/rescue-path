import SwiftUI

/// Secondary view behind [MAP]: the top-down floor plan, heading controls,
/// detections, the alert log and settings.
struct MapScreen: View {
    let store: RadarStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    tacText("FLOOR PLAN", 14, .bold).foregroundStyle(Theme.ink)
                    tacText("DRAG MARKER TO MOVE", 11).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    tacText("[CLOSE]", 13, .bold)
                        .foregroundStyle(Theme.line)
                        .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Hairline().padding(.horizontal, 16)

            RadarMapView(store: store)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            ControlBar(store: store)

            Hairline().padding(.horizontal, 16)

            DetectionSheet(store: store)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay { Scanlines().ignoresSafeArea() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }
}
