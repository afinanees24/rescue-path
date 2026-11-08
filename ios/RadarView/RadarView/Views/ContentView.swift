import SwiftUI
import UIKit

/// Launch: pick a role. FIREFIGHTER runs the radar + bracelets; BEACON is the hidden
/// person's phone and only joins the UWB session.
struct ContentView: View {
    @State private var role: AppRole?

    var body: some View {
        Group {
            switch role {
            case nil:
                RoleSelectView { role = $0 }
            case .firefighter:
                FirefighterRoot { role = $0 }
            case .beacon:
                BeaconScreen { role = nil }
            }
        }
        .onAppear {
            // iOS pauses BLE and NI when the app backgrounds; keep it awake and in front.
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}

struct FirefighterRoot: View {
    let onSwitchRole: (AppRole) -> Void
    @State private var store = RadarStore()

    var body: some View {
        RadarScreen(store: store, onSwitchRole: onSwitchRole)
            .onAppear { store.start() }
            .onDisappear { store.stop() }
    }
}

struct RoleSelectView: View {
    let onSelect: (AppRole) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                tacText("FF-RADAR", 14, .bold).foregroundStyle(Theme.ink)
                tacText("SELECT ROLE", 11).foregroundStyle(Theme.dim)
            }
            .padding(.vertical, 12)
            Hairline()
            Spacer()
            roleButton("FIREFIGHTER", "RADAR + BRACELETS. THIS PHONE FACES FORWARD.", .firefighter)
                .padding(.bottom, 28)
            roleButton("BEACON", "HIDDEN PERSON'S PHONE. HOLD AT CHEST HEIGHT, SCREEN OUT.", .beacon)
            Spacer()
            Hairline()
            tacText("WAIST ON · BRACELETS ON · FIREFIGHTER · THEN BEACON", 10)
                .foregroundStyle(Theme.dim)
                .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .background(Color.black.ignoresSafeArea())
        .overlay { Scanlines().ignoresSafeArea() }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    private func roleButton(_ title: String, _ detail: String, _ role: AppRole) -> some View {
        Button { onSelect(role) } label: {
            VStack(alignment: .leading, spacing: 8) {
                tacText("[ \(title) ]", 22, .bold).foregroundStyle(Theme.cyan).glow(Theme.cyan, radius: 3)
                tacText(detail, 10).foregroundStyle(Theme.dim).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(.horizontal, 14)
            .overlay(Rectangle().stroke(Theme.faint, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
