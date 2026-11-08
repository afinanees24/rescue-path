import SwiftUI

/// [LOG]: bracelet command log, UWB state steps, board tests and the role switch.
struct LogSheet: View {
    let store: RadarStore
    var onSwitchRole: (AppRole) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var lastTest = ""

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    tacText("FF-RADAR", 14, .bold).foregroundStyle(Theme.ink)
                    tacText("LOG", 11, .bold).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button { dismiss() } label: {
                    tacText("[CLOSE]", 13, .bold).foregroundStyle(Theme.line)
                        .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    braceletSection
                    uwbSection
                    waistSection
                    commandLogSection
                    ruleLogSection
                    roleSection
                }
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 16)
        .background(Color.black.ignoresSafeArea())
        .overlay { Scanlines().ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    // MARK: Bracelets

    private var braceletSection: some View {
        section("BRACELETS") {
            HStack(spacing: 12) {
                testButton("TEST LEFT", .left)
                testButton("TEST RIGHT", .right)
            }
            if !lastTest.isEmpty {
                tacText(lastTest, 11).foregroundStyle(Theme.dim)
            }
            ForEach(Side.allCases, id: \.self) { side in
                HStack {
                    statusDot(store.boards.isReady(side.board))
                    tacText(side.board.rawValue.uppercased(), 12).foregroundStyle(Theme.ink)
                    Spacer()
                    if let e = store.boards.lastSent[side] {
                        tacText("LAST \(e.cmd) · \(Self.time.string(from: e.time))", 11).foregroundStyle(Theme.ping)
                    } else {
                        tacText("LAST --", 11).foregroundStyle(Theme.dim)
                    }
                }
            }
            tacText("SENT \(store.boards.writes) · DROPPED \(store.boards.droppedWrites)", 10)
                .foregroundStyle(Theme.dim)
        }
    }

    private func testButton(_ title: String, _ side: Side) -> some View {
        let ready = store.boards.isReady(side.board)
        return Button {
            let ok = store.boards.write(.test, to: side)
            lastTest = "\(title): \(ok ? "SENT FF 32" : "NOT CONNECTED")"
        } label: {
            tacText("[\(title)]", 13, .bold)
                .foregroundStyle(ready ? Theme.ping : Theme.dim)
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay(Rectangle().stroke(ready ? Theme.ping : Theme.faint, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: UWB steps

    private var uwbSection: some View {
        let u = store.uwb
        return section("UWB") {
            TimelineView(.periodic(from: .now, by: 0.2)) { tl in
                let fresh = u.isFresh(now: tl.date)
                VStack(alignment: .leading, spacing: 8) {
                    step("SEARCHING PEER", done: u.peerName != nil,
                         detail: u.peerName ?? (u.status == .unsupported ? "NO UWB CHIP" : "WAITING"))
                    step("TOKEN EXCHANGED", done: u.tokenExchanged, detail: nil)
                    step("RANGING", done: fresh,
                         detail: fresh ? u.distance.map { String(format: "%.2fM", $0) } : nil)
                    if u.cameraAssist {
                        step("CAMERA ASSIST", done: true,
                             detail: u.convergence.isEmpty ? nil : u.convergence.uppercased())
                    }
                    step(fresh && u.bearing != nil ? "DIRECTION OK" : "NO DIRECTION",
                         done: fresh && u.bearing != nil,
                         detail: fresh ? u.bearing.map { String(format: "%+.0f°", $0) } : nil)
                }
            }
            if u.cameraAssist {
                Toggle(isOn: Binding(get: { u.flipHorizontalAngle }, set: { u.flipHorizontalAngle = $0 })) {
                    tacText("FLIP LEFT/RIGHT (CAMERA ANGLE)", 11).foregroundStyle(Theme.ink)
                }
                .tint(Theme.teal)
            }
            if let err = u.lastError {
                tacText(err.uppercased(), 10).foregroundStyle(Theme.red)
            }
        }
    }

    private func step(_ title: String, done: Bool, detail: String?) -> some View {
        HStack(spacing: 10) {
            statusDot(done)
            tacText(title, 12, .bold).foregroundStyle(done ? Theme.ink : Theme.dim)
            Spacer()
            if let detail { tacText(detail, 11).foregroundStyle(done ? Theme.teal : Theme.dim) }
        }
    }

    // MARK: Waist

    private var waistSection: some View {
        section("WAIST") {
            TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                let us = store.boards.currentUS(now: tl.date)
                HStack {
                    statusDot(store.boards.isReady(.waist))
                    tacText(us.map { $0 < 0 ? "US NO ECHO" : "US \($0) CM" } ?? "US --", 12, .bold)
                        .foregroundStyle(us.map { $0 > 0 && $0 < 60 } == true ? Theme.red : Theme.ink)
                    Spacer()
                    tacText(String(format: "RX %.0fHz", store.boards.waistRate), 11).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    // MARK: Logs

    private var commandLogSection: some View {
        section("BRACELET COMMANDS") {
            if store.boards.commandLog.isEmpty {
                tacText("NOTHING SENT YET", 11).foregroundStyle(Theme.dim)
            }
            ForEach(store.boards.commandLog.prefix(40)) { e in
                HStack(spacing: 10) {
                    tacText(Self.time.string(from: e.time), 10).foregroundStyle(Theme.dim)
                    tacText(e.side.short, 11, .bold).foregroundStyle(Theme.ink)
                    tacText(e.cmd.description, 11, .bold).foregroundStyle(e.sent ? Theme.ping : Theme.dim)
                    if !e.sent { tacText("DROPPED", 10).foregroundStyle(Theme.red) }
                }
            }
        }
    }

    private var ruleLogSection: some View {
        section("RULE \(store.guidance.rule.rawValue) · \(store.guidance.rule.cue)") {
            ForEach(store.guidance.log.prefix(30)) { e in
                HStack(spacing: 10) {
                    tacText(Self.time.string(from: e.time), 10).foregroundStyle(Theme.dim)
                    tacText("R\(e.rule.rawValue) \(e.rule.cue)", 11, .bold)
                        .foregroundStyle(e.rule == .stop ? Theme.red : Theme.ink)
                    tacText(e.detail, 10).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    // MARK: Role

    private var roleSection: some View {
        section("ROLE") {
            HStack(spacing: 12) {
                roleButton("FIREFIGHTER", active: true) { dismiss() }
                roleButton("BEACON", active: false) {
                    dismiss()
                    onSwitchRole(.beacon)
                }
            }
        }
    }

    private func roleButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tacText("[\(title)]", 13, .bold)
                .foregroundStyle(active ? Theme.teal : Theme.line)
                .frame(maxWidth: .infinity, minHeight: 50)
                .overlay(Rectangle().stroke(active ? Theme.teal : Theme.faint, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func statusDot(_ on: Bool) -> some View {
        Circle()
            .fill(on ? Theme.cyan : Color.clear)
            .overlay(Circle().stroke(on ? Theme.cyan : Theme.dim, lineWidth: 1))
            .frame(width: 8, height: 8)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            tacText(title, 11, .bold).foregroundStyle(Theme.dim)
            Rectangle().fill(Theme.faint).frame(height: 1)
            content()
        }
    }
}
