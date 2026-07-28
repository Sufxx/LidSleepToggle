import WidgetKit
import SwiftUI
import AppIntents

// Home Screen + Lock Screen widget. The timeline fetches the Mac's latest
// status snapshot; medium/large sizes get interactive buttons (iOS 17+) that
// fire App Intents without opening the app.

struct LidEntry: TimelineEntry {
    let date: Date
    let status: LidStatus?
    let paired: Bool
}

struct LidProvider: TimelineProvider {
    func placeholder(in context: Context) -> LidEntry {
        LidEntry(date: Date(), status: .placeholder, paired: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (LidEntry) -> Void) {
        Task {
            let s = LidStore.isPaired ? await LidClient.fetchStatus() : nil
            completion(LidEntry(date: Date(), status: s ?? .placeholder, paired: LidStore.isPaired))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LidEntry>) -> Void) {
        Task {
            let paired = LidStore.isPaired
            let s = paired ? await LidClient.fetchStatus() : nil
            let entry = LidEntry(date: Date(), status: s, paired: paired)
            // Refresh cadence: WidgetKit coalesces these, ~every 15 min in practice.
            let next = Calendar.current.date(byAdding: .minute, value: 10, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct LidWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: LidEntry

    var body: some View {
        if !entry.paired {
            unpaired
        } else if let s = entry.status {
            switch family {
            case .systemSmall: small(s)
            case .accessoryRectangular: lockRect(s)
            case .accessoryInline: lockInline(s)
            case .accessoryCircular: lockCircular(s)
            default: medium(s)
            }
        } else {
            unreachable
        }
    }

    // MARK: Home Screen

    private func small(_ s: LidStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: s.statusSymbol).foregroundStyle(s.accent)
                Spacer()
                Text(s.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(s.headline).font(.headline).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                miniChip(s.batterySymbol, s.batteryText, s.batteryTint)
                if s.temp >= 0 { miniChip("thermometer.medium", "\(s.temp)°", s.tempTint) }
            }
            Button(intent: SleepMacIntent()) {
                Text("Sleep").font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.small).tint(.accentColor)
        }
    }

    private func medium(_ s: LidStatus) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: s.statusSymbol).foregroundStyle(s.accent)
                    Text(s.modeTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(s.subline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    miniChip(s.batterySymbol, s.batteryText, s.batteryTint)
                    if s.temp >= 0 { miniChip("thermometer.medium", "\(s.temp)°C", s.tempTint) }
                    miniChip(s.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                             s.lidClosed ? "Shut" : "Open", .secondary)
                }
            }
            Divider()
            VStack(spacing: 8) {
                Button(intent: SleepMacIntent()) {
                    Label("Sleep", systemImage: "powersleep")
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.accentColor)
                Button(intent: SetModeIntent(mode: .auto)) {
                    Label("Auto", systemImage: "bolt.badge.automatic.fill")
                        .font(.caption).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(intent: RefreshIntent()) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption2).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 96)
        }
    }

    private func miniChip(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2)
            Text(text).font(.caption2.weight(.medium)).monospacedDigit()
        }
        .foregroundStyle(tint)
    }

    // MARK: Lock Screen

    private func lockRect(_ s: LidStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: s.statusSymbol)
                Text(s.modeTitle).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(s.headline).font(.caption2).lineLimit(1)
            HStack(spacing: 8) {
                Label(s.batteryText, systemImage: s.batterySymbol)
                if s.temp >= 0 { Label("\(s.temp)°", systemImage: "thermometer.medium") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func lockInline(_ s: LidStatus) -> some View {
        Label("\(s.modeTitle) · \(s.batteryText)", systemImage: s.statusSymbol)
    }
    private func lockCircular(_ s: LidStatus) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: s.statusSymbol).font(.title3)
        }
    }

    // MARK: States

    private var unpaired: some View {
        VStack(spacing: 6) {
            Image(systemName: "laptopcomputer.and.iphone").font(.title2)
            Text("Open the app to connect your Mac").font(.caption2)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
    private var unreachable: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.orange)
            Text("Mac unreachable").font(.caption).foregroundStyle(.secondary)
            Button(intent: RefreshIntent()) {
                Text("Retry").font(.caption2)
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }
}

struct LidWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LidWidget", provider: LidProvider()) { entry in
            LidWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Lid Sleep")
        .description("See and control your Mac's lid-close sleep.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryRectangular, .accessoryInline, .accessoryCircular,
        ])
    }
}

@main
struct LidWidgetBundle: WidgetBundle {
    var body: some Widget {
        LidWidget()
        if #available(iOS 18.0, *) { LidControl() }
    }
}
