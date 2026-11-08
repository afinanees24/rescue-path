import SwiftUI
import UIKit

/// Launch: pick a role. FIREFIGHTER runs the radar + bracelets; BEACON is the hidden
/// person's phone and only joins the UWB session.
struct ContentView: View {
    /// Each phone remembers its role and opens straight into it.
    /// (A `-role firefighter|beacon` launch argument overrides it.)
    @State private var role: AppRole? = AppRole(rawValue: UserDefaults.standard.string(forKey: Self.roleKey) ?? "")

    static let roleKey = "role"

    var body: some View {
        Group {
            switch role {
            case nil:
                RoleSelectView { choose($0) }
            case .firefighter:
                FirefighterRoot { choose($0) }
            case .beacon:
                BeaconScreen { choose(nil) }
            }
        }
        .onAppear {
            // iOS pauses BLE, NI and ARKit when the app backgrounds; keep it awake and in front.
            UIApplication.shared.isIdleTimerDisabled = true
            if let role { choose(role) }      // also remembers a role given as a launch argument
        }
    }

    private func choose(_ r: AppRole?) {
        if let r { UserDefaults.standard.set(r.rawValue, forKey: Self.roleKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.roleKey) }
        role = r
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
