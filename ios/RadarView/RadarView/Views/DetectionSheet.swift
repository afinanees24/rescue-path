import SwiftUI

/// Lower half of the MAP view: current target, the rule-change log, settings.
struct DetectionSheet: View {
    @Bindable var store: RadarStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                targetSection
                ruleLog
                settings
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "TARGET · \(store.sourceKind.label)")
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(store.fix.distance == nil ? Theme.faint : Theme.cyan)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    tacText(store.guidance.rule.cue, 16, .bold)
                        .foregroundStyle(store.guidance.rule == .stop ? Theme.red : Theme.cyan)
                    tacText(bearingText, 12).foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 8)
                Text(store.fix.distance.map { String(format: "%.1fm", $0) } ?? "--")
                    .font(Theme.mono(30, .medium))
                    .foregroundStyle(store.fix.distance == nil ? Theme.dim : Theme.ink)
            }
            .padding(12)
            .frame(minHeight: 64)
            .overlay(Rectangle().stroke(Theme.faint, lineWidth: 1))
        }
    }

    private var bearingText: String {
        if !store.providesBearing { return "BRG N/A (RADAR)" }
        guard let b = store.fix.bearing else { return "BRG -- (SWEEP)" }
        return String(format: "BRG %+.0f°", b)
    }

    // MARK: Rule log

    private var ruleLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "RULE LOG")
                Spacer()
                if !store.guidance.log.isEmpty {
                    Button("[CLEAR]") { store.guidance.clearLog() }
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.dim)
                        .frame(minHeight: 44)
                }
            }
            if store.guidance.log.isEmpty {
                tacText("NO RULE CHANGES YET", 11).foregroundStyle(Theme.dim)
            }
            ForEach(store.guidance.log.prefix(50)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    tacText(Self.timeFormatter.string(from: e.time), 11).foregroundStyle(Theme.dim)
                    tacText("R\(e.rule.rawValue) \(e.rule.cue)", 12, .bold)
                        .foregroundStyle(e.rule == .stop ? Theme.red : Theme.ink)
                    tacText(e.detail, 11).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SETTINGS")

            Picker("Target source", selection: Binding(get: { store.sourceKind }, set: { store.setSource($0) })) {
                ForEach(SourceKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $store.showTruth) {
                tacText("SHOW SIMULATED PERSON", 12).foregroundStyle(Theme.ink)
            }
            .tint(Theme.cyan)
            .disabled(store.sourceKind != .sim)
            .frame(minHeight: 44)

            SettingButton(title: "ALIGN MAP TO MY FACING", systemImage: "location.north.line") {
                store.alignMapToFacing()
            }
            .disabled(!store.compass.hasReading)

            SettingButton(title: "CLEAR SCAN DOTS", systemImage: "trash") {
                store.clearBlips()
            }

            SettingButton(title: "NEW SIMULATED PERSON", systemImage: "shuffle") {
                store.newScenario()
            }
            .disabled(store.sourceKind != .sim)

            tacText("DRAG THE MARKER TO MOVE. TWIST TWO FINGERS ON THE MAP, OR USE THE ROTATE BUTTONS, TO SET HEADING BY HAND.", 10)
                .foregroundStyle(Theme.dim)
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        tacText(title, 11, .bold).foregroundStyle(Theme.dim)
    }
}

struct SettingButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                tacText(title, 12, .bold)
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .padding(.horizontal, 14)
            .overlay(Rectangle().stroke(Theme.faint, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
    }
}
