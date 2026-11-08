import SwiftUI

/// [LOG]: bracelet command log, UWB state steps, board tests and the role switch.
struct LogSheet: View {
    let store: RadarStore
    var onSwitchRole: (AppRole) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

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
        .onDisappear { store.guidance.setTest(nil) }     // closing the panel hands back to navigation
    }

    // MARK: Bracelets

    private var braceletSection: some View {
        section("HAPTICS TEST") {
            testRow([.forward])
            testRow([.left, .right])
            testRow([.stop, .off])

            HStack(spacing: 10) {
                tacText("INTENSITY", 11, .bold).foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { store.guidance.testIntensity },
                                      set: { store.guidance.testIntensity = $0 }), in: 70...255, step: 1)
                    .tint(Theme.teal)
                tacText("\(Int(store.guidance.testIntensity))", 13, .bold).foregroundStyle(Theme.ink)
                    .frame(width: 44, alignment: .trailing)
            }

            TimelineView(.periodic(from: .now, by: 0.2)) { tl in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Side.allCases, id: \.self) { side in
                        braceletRow(side, now: tl.date)
                    }
                }
            }
            tacText("SENT \(store.boards.writes) · DROPPED \(store.boards.droppedWrites)", 10)
                .foregroundStyle(Theme.dim)
            tacText("✓ = THE BRACELET ACKNOWLEDGED A TEST WRITE", 10).foregroundStyle(Theme.dim)
        }
    }

    private func testRow(_ tests: [HapticTest]) -> some View {
        HStack(spacing: 12) {
            ForEach(tests) { testButton($0) }
        }
    }

    private func testButton(_ t: HapticTest) -> some View {
        let active = store.guidance.test == t
        let title = t == .forward ? "FORWARD (RIPPLE)" : t.rawValue
        return Button {
            store.guidance.setTest(t)
        } label: {
            tacText("[\(title)]", 14, .bold)
                .foregroundStyle(active ? Color.black : Theme.ping)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(active ? Theme.ping : Color.clear)
                .overlay(Rectangle().stroke(Theme.ping, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func braceletRow(_ side: Side, now: Date) -> some View {
        let acked = store.boards.lastAck[side].map { now.timeIntervalSince($0) < 1.5 } ?? false
        let error = store.boards.lastWriteError[side]
        return HStack(spacing: 8) {
            statusDot(store.boards.isReady(side.board))
            tacText(side.board.rawValue.uppercased(), 12).foregroundStyle(Theme.ink)
            if store.boards.needsPowerCycle(side.board, now: now) {
                tacText("POWER-CYCLE IT", 10, .bold).foregroundStyle(Theme.red)
            }
            Spacer()
            if let e = store.boards.lastSent[side] {
                tacText("\(e.bytes) · \(Self.time.string(from: e.time))", 11).foregroundStyle(Theme.ping)
            } else {
                tacText("--", 11).foregroundStyle(Theme.dim)
            }
            tacText(error != nil ? "✗" : (acked ? "✓" : " "), 14, .bold)
                .foregroundStyle(error != nil ? Theme.red : Theme.teal)
                .frame(width: 18)
        }
    }

    // MARK: UWB steps

    private var uwbSection: some View {
        let u = store.uwb
        let b = store.boards
        return section("UWB · \(u.deviceModel) · \(u.mode.rawValue)") {
            TimelineView(.periodic(from: .now, by: 0.2)) { tl in
                let fresh = u.isFresh(now: tl.date)
                VStack(alignment: .leading, spacing: 8) {
                    step("BEACON FOUND (BLE)", done: b.beaconState != .none, detail: b.beaconState.rawValue)
                    step("BEACON TOKEN READ", done: b.tokenReads > 0, detail: b.tokenReads > 0 ? "×\(b.tokenReads)" : nil)
                    step("OUR TOKEN WRITTEN", done: b.tokenWrites > 0, detail: b.tokenWrites > 0 ? "×\(b.tokenWrites)" : nil)
                    step("RANGING", done: fresh, detail: fresh ? u.distance.map { String(format: "%.2fM", $0) } : nil)
                    step(u.direction != nil && fresh ? "DIRECTION VALID" : "NO DIRECTION", done: u.direction != nil && fresh,
                         detail: u.direction.map { String(format: "%+.0f°", Double(atan2($0.x, -$0.z)) * 180 / .pi) })
                    if u.cameraAssistSupported {
                        step("CAMERA ASSIST \(u.cameraOn ? "ON" : "OFF")", done: u.cameraOn,
                             detail: u.cameraOn ? (u.convergence.isEmpty ? "AR \(u.arTracking)" : u.convergence) : nil)
                    }
                    step("DIRECTION HARDWARE", done: u.supportsDirection, detail: u.supportsDirection ? "YES" : "NO")
                    step("BEARING SOURCE", done: store.bearingSource != .none, detail: store.bearingSource.rawValue)
                    step("MAX DIST WITH DIRECTION", done: u.maxDirectionDistance > 0,
                         detail: u.maxDirectionDistance > 0 ? String(format: "%.1f M", u.maxDirectionDistance) : "--")
                    step("TRILATERATION", done: store.bearingSource == .trilaterationAR || store.bearingSource == .trilaterationSteps,
                         detail: store.trilaterationInfo)
                    step("STEPS", done: store.steps.available,
                         detail: store.steps.available ? String(format: "%.1f M WALKED · %.1f M/S", store.steps.walked, store.steps.speed) : "UNAVAILABLE")
                    step("HEADING (GYRO)", done: store.motion.calibrated,
                         detail: store.motion.available
                            ? "\(store.motion.candidateName)\(store.motion.calibrated ? "" : " · TURN TO CHECK")"
                            : "NO MOTION")
                    step("BLE RSSI", done: b.beaconRSSI != nil,
                         detail: b.beaconRSSI.map { String(format: "%.0f dBm", $0) })
                }
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
            ForEach(store.boards.commandLog.prefix(60)) { e in
                HStack(spacing: 10) {
                    tacText(Self.time.string(from: e.time), 10).foregroundStyle(Theme.dim)
                    tacText(e.side.short, 11, .bold).foregroundStyle(Theme.ink)
                    tacText(e.bytes, 11, .bold).foregroundStyle(e.sent ? Theme.ping : Theme.dim)
                    if !e.sent { tacText("DROPPED", 10).foregroundStyle(Theme.red) }
                }
            }
        }
    }

    private var ruleLogSection: some View {
        section("CUE · \(store.guidance.sentLabel) · OBSTACLE \(store.guidance.detourState)"
                + (store.guidance.detourHeading.map { String(format: " · DETOUR HDG %.0f°", $0) } ?? "")) {
            ForEach(store.guidance.log.prefix(30)) { e in
                HStack(spacing: 10) {
                    tacText(Self.time.string(from: e.time), 10).foregroundStyle(Theme.dim)
                    tacText(e.cue.label, 11, .bold)
                        .foregroundStyle(e.cue == .stop ? Theme.red : Theme.ink)
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
