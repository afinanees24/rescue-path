import SwiftUI

/// Hidden board-check panel (long-press the header).
struct DebugPanel: View {
    let store: RadarStore
    var onExit: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var lastTest = ""

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    tacText("DEBUG", 14, .bold).foregroundStyle(Theme.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        tacText("[CLOSE]", 13, .bold).foregroundStyle(Theme.line)
                            .frame(minWidth: 88, minHeight: 44, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }

                section("BRACELETS") {
                    HStack(spacing: 12) {
                        testButton("TEST LEFT", .left)
                        testButton("TEST RIGHT", .right)
                    }
                    if !lastTest.isEmpty {
                        tacText(lastTest, 11).foregroundStyle(Theme.dim)
                    }
                    tacText("WRITES \(store.boards.writes) · DROPPED \(store.boards.droppedWrites)", 11)
                        .foregroundStyle(Theme.dim)
                }

                section("RULE") {
                    tacText("RULE \(store.guidance.rule.rawValue) · \(store.guidance.rule.cue)", 16, .bold)
                        .foregroundStyle(store.guidance.rule == .stop ? Theme.red : Theme.cyan)
                }

                section("WAIST") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                        let us = store.boards.currentUS(now: tl.date)
                        HStack(alignment: .firstTextBaseline) {
                            tacText("US", 12, .bold).foregroundStyle(Theme.dim)
                            Text(usText(us))
                                .font(.system(size: 34, weight: .medium, design: .monospaced))
                                .foregroundStyle(us.map { $0 > 0 && $0 < 60 } == true ? Theme.red : Theme.ink)
                            Spacer()
                            tacText(String(format: "RX %.0fHz", store.boards.waistRate), 11)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    tacText(store.boards.waistRaw.isEmpty ? "NO DATA" : store.boards.waistRaw, 10)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                }

                section("UWB · \(store.uwb.status.label)") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                        let fresh = store.uwb.isFresh(now: tl.date)
                        HStack(alignment: .firstTextBaseline) {
                            tacText("DIST", 12, .bold).foregroundStyle(Theme.dim)
                            Text(fresh ? store.uwb.distance.map { String(format: "%.2fm", $0) } ?? "--" : "--")
                                .font(.system(size: 34, weight: .medium, design: .monospaced))
                                .foregroundStyle(fresh ? Theme.cyan : Theme.dim)
                            Spacer()
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                        let fresh = store.uwb.isFresh(now: tl.date)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                tacText("BRG", 12, .bold).foregroundStyle(Theme.dim)
                                Text(fresh ? store.uwb.bearing.map { String(format: "%+.0f°", $0) } ?? "NIL" : "--")
                                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                                    .foregroundStyle(fresh && store.uwb.bearing != nil ? Theme.cyan : Theme.dim)
                                Spacer()
                            }
                            tacText(rawText, 10).foregroundStyle(Theme.dim)
                        }
                    }
                    tacText("PEER \(store.uwb.peerName ?? "NONE")", 11).foregroundStyle(Theme.dim)
                    tacText("DIRECTION HW \(store.uwb.supportsDirection ? "YES" : "NO") · CAMERA ASSIST \(store.uwb.cameraAssist ? "ON" : "OFF")", 10)
                        .foregroundStyle(Theme.dim)
                    if !store.uwb.convergence.isEmpty {
                        tacText("CONVERGENCE \(store.uwb.convergence.uppercased())", 10).foregroundStyle(Theme.dim)
                    }
                    if store.uwb.cameraAssist {
                        Toggle(isOn: Binding(get: { store.uwb.flipHorizontalAngle },
                                             set: { store.uwb.flipHorizontalAngle = $0 })) {
                            tacText("FLIP LEFT/RIGHT (CAMERA ANGLE)", 11).foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.cyan)
                    }
                    if let err = store.uwb.lastError {
                        tacText(err.uppercased(), 10).foregroundStyle(Theme.red)
                    }
                }

                section("BOARDS · BT \(store.boards.bluetooth)") {
                    ForEach(BoardRole.allCases) { role in
                        HStack {
                            Circle()
                                .fill(store.boards.isReady(role) ? Theme.cyan : Color.clear)
                                .overlay(Circle().stroke(store.boards.isReady(role) ? Theme.cyan : Theme.dim, lineWidth: 1))
                                .frame(width: 8, height: 8)
                            tacText(role.rawValue.uppercased(), 12).foregroundStyle(Theme.ink)
                            Spacer()
                            tacText(store.boards.isReady(role) ? "READY" : "SEARCHING", 11)
                                .foregroundStyle(store.boards.isReady(role) ? Theme.cyan : Theme.dim)
                        }
                    }
                }

                section("RULE LOG") {
                    if store.guidance.log.isEmpty {
                        tacText("NO RULE CHANGES YET", 11).foregroundStyle(Theme.dim)
                    }
                    ForEach(store.guidance.log.prefix(60)) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            tacText(Self.time.string(from: e.time), 10).foregroundStyle(Theme.dim)
                            tacText("R\(e.rule.rawValue) \(e.rule.cue)", 11, .bold)
                                .foregroundStyle(e.rule == .stop ? Theme.red : Theme.ink)
                            tacText(e.detail, 10).foregroundStyle(Theme.dim)
                        }
                    }
                }

                Button {
                    dismiss()
                    onExit()
                } label: {
                    tacText("[SWITCH ROLE]", 13, .bold).foregroundStyle(Theme.line)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(Rectangle().stroke(Theme.faint, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var rawText: String {
        if let d = store.uwb.rawDirection {
            return String(format: "DIR x %+.2f y %+.2f z %+.2f", d.x, d.y, d.z)
        }
        if let h = store.uwb.rawHorizontalAngle {
            return String(format: "H-ANGLE %+.1f°", Double(h) * 180 / .pi)
        }
        return "NO DIRECTION (OUTSIDE ±45° OR WEAK)"
    }

    private func usText(_ us: Int?) -> String {
        guard let us else { return "--" }
        return us < 0 ? "NO ECHO" : "\(us) cm"
    }

    private func testButton(_ title: String, _ side: Side) -> some View {
        Button {
            let ok = store.boards.write(.test, to: side)
            lastTest = "\(title): \(ok ? "SENT FF 32" : "NOT CONNECTED")"
        } label: {
            tacText("[\(title)]", 13, .bold)
                .foregroundStyle(store.boards.isReady(side.board) ? Theme.cyan : Theme.dim)
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay(Rectangle().stroke(store.boards.isReady(side.board) ? Theme.cyan : Theme.faint, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            tacText(title, 11, .bold).foregroundStyle(Theme.dim)
            Hairline().opacity(0.4)
            content()
        }
    }
}
