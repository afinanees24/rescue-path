import SwiftUI

/// Bottom sheet: current detections, alert log, settings.
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
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    detections(now: timeline.date)
                }
                alertLog
                settings
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Detections

    private func detections(now: Date) -> some View {
        let visible = TargetKind.allCases
            .compactMap { store.detections[$0] }
            .filter { now.timeIntervalSince($0.lastSeen) < RadarStore.blipLifetime }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "DETECTIONS")
            if visible.isEmpty {
                Text("No one detected. Sweep the cone slowly across each room.")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(visible) { d in
                DetectionRow(detection: d, now: now)
            }
        }
    }

    // MARK: Alert log

    private var alertLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "ALERT LOG")
                Spacer()
                if !store.alerts.isEmpty {
                    Button("Clear") { store.clearAlerts() }
                        .font(Theme.mono(14, .bold))
                        .foregroundStyle(Theme.dim)
                        .frame(minHeight: 44)
                }
            }
            if store.alerts.isEmpty {
                Text("No alerts yet.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(store.alerts.prefix(50)) { a in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.timeFormatter.string(from: a.time))
                        .font(Theme.mono(13, .semibold))
                        .foregroundStyle(Theme.dim)
                    Circle()
                        .fill(Theme.color(for: a.kind))
                        .frame(width: 9, height: 9)
                    Text(a.text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SETTINGS")

            Picker("Data source", selection: Binding(get: { store.mode }, set: { store.setMode($0) })) {
                ForEach(DataMode.allCases) { mode in
                    Text(mode.badge).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if store.mode == .live {
                Text("Looking for \"\(BLERadarClient.deviceName)\" · \(store.ble.state.label)")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.dim)
            }

            Toggle("Show simulated people", isOn: $store.showTruth)
                .font(.system(size: 16, weight: .semibold))
                .tint(Theme.radar)
                .disabled(store.mode != .simulated)
                .frame(minHeight: 44)

            SettingButton(title: "Align map to the way I'm facing", systemImage: "location.north.line") {
                store.alignMapToFacing()
            }
            .disabled(!store.compass.hasReading)

            SettingButton(title: "Clear scan blips", systemImage: "trash") {
                store.clearBlips()
            }

            SettingButton(title: "New simulated scenario", systemImage: "shuffle") {
                store.newScenario()
            }
            .disabled(store.mode != .simulated)

            Text("Drag the blue marker to move. Twist two fingers on the map, or use the rotate buttons, to set heading by hand.")
                .font(.footnote)
                .foregroundStyle(Theme.dim)
        }
    }
}

struct DetectionRow: View {
    let detection: Detection
    let now: Date

    var body: some View {
        let color = Theme.color(for: detection.kind)
        let age = max(0, now.timeIntervalSince(detection.lastSeen))
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(detection.kind.title)
                    .font(Theme.mono(18, .heavy))
                    .foregroundStyle(color)
                if detection.kind == .still {
                    Text("POSSIBLY UNCONSCIOUS")
                        .font(Theme.mono(12, .heavy))
                        .foregroundStyle(Theme.still)
                }
                Text("BRG \(Compass.label(detection.bearing)) · \(age < 1.5 ? "now" : "\(Int(age)) s ago")")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 8)
            Text(String(format: "%.1f m", detection.distance))
                .font(Theme.mono(32, .heavy))
                .foregroundStyle(Theme.text)
        }
        .padding(12)
        .frame(minHeight: 64)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
        .opacity(age > 2 ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.mono(13, .heavy))
            .tracking(1.5)
            .foregroundStyle(Theme.dim)
    }
}

struct SettingButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }
}
