import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = RadarStore()

    var body: some View {
        RadarScreen(store: store)
            .onAppear {
                store.start()
                UIApplication.shared.isIdleTimerDisabled = true
            }
    }
}
