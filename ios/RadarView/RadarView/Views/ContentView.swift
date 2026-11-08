import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = RadarStore()
    @State private var detent: PresentationDetent = ContentView.peekDetent

    static let peekHeight: CGFloat = 150
    static let peekDetent = PresentationDetent.height(peekHeight)

    var body: some View {
        VStack(spacing: 0) {
            StatusBarView(store: store)
            RadarMapView(store: store)
            ControlBar(store: store)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Keep the controls above the collapsed sheet.
            Color.clear.frame(height: Self.peekHeight - 20)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: .constant(true)) {
            DetectionSheet(store: store)
                .presentationDetents([Self.peekDetent, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.panel)
                .interactiveDismissDisabled()
                .preferredColorScheme(.dark)
        }
        .onAppear {
            store.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}
