import WidgetKit
import SwiftUI
import AppIntents

// Home Screen + Lock Screen widget. Night-utility styling shared with the app:
// midnight gradient, yellow = awake, indigo = sleep. Interactive buttons fire
// App Intents over the relay without opening the app.

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
            let next = Calendar.current.date(byAdding: .minute, value: 10, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Shared pieces

private struct StatusOrb: View {
    let status: LidStatus
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(status.accent.opacity(0.22))
            Circle()
                .strokeBorder(status.accent.opacity(0.4), lineWidth: 1)
            Image(systemName: status.statusSymbol)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(status.accent)
        }
        .frame(width: size, height: size)
        .shadow(color: status.accent.opacity(0.45), radius: size * 0.35)
    }
}

private struct StatChip: View {
    let symbol: String
    let text: String
    var tint: Color = .white.opacity(0.7)

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Lid.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(Lid.glassStroke, lineWidth: 0.5))
    }
}

// One action tile in the 2×2 grid.
private struct ActionTile<I: AppIntent>: View {
    let intent: I
    let symbol: String
    let label: String
    var active: Bool = false
    var accent: Color = Lid.indigo

    var body: some View {
        Button(intent: intent) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Lid.midnight : .white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                active ? AnyShapeStyle(accent) : AnyShapeStyle(Lid.glass),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(active ? accent.opacity(0.9) : Lid.glassStroke, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widget views

struct LidWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: LidEntry

    var body: some View {
        Group {
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
    }

    // MARK: Medium — status left, 2×2 actions right

    private func medium(_ s: LidStatus) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    StatusOrb(status: s, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.headline)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(s.host)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    StatChip(symbol: s.batterySymbol, text: s.batteryText,
                             tint: s.charging ? .green : (s.battery <= 20 ? .orange : .white.opacity(0.7)))
                    if s.temp >= 0 { StatChip(symbol: "thermometer.medium", text: "\(s.temp)°") }
                    StatChip(symbol: s.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                             text: s.lidClosed ? "Shut" : "Open",
                             tint: s.lidClosed && s.awake ? Lid.yellow : .white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ActionTile(intent: SleepMacIntent(), symbol: "moon.zzz.fill", label: "Sleep",
                               accent: Lid.indigo)
                    ActionTile(intent: SetModeIntent(mode: .always), symbol: "bolt.fill", label: "Awake",
                               active: s.mode == "always", accent: Lid.yellow)
                }
                GridRow {
                    ActionTile(intent: SetModeIntent(mode: .auto), symbol: "bolt.badge.automatic.fill",
                               label: "Auto", active: s.mode == "auto", accent: Lid.yellow)
                    ActionTile(intent: RefreshIntent(), symbol: "arrow.clockwise", label: "Refresh")
                }
            }
            .frame(width: 128)
        }
    }

    // MARK: Small — status + one smart action

    private func small(_ s: LidStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                StatusOrb(status: s, size: 32)
                Spacer()
                StatChip(symbol: s.batterySymbol, text: s.batteryText,
                         tint: s.charging ? .green : (s.battery <= 20 ? .orange : .white.opacity(0.7)))
            }
            Spacer(minLength: 4)
            Text(s.headline)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if s.temp >= 0 {
                Text("\(s.temp)°C · \(s.lidClosed ? "lid shut" : "lid open")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 6)
            // The one action that matters given the current state.
            if s.awake {
                smartButton(intent: SleepMacIntent(), symbol: "moon.zzz.fill",
                            label: "Sleep", fill: AnyShapeStyle(Lid.sleepGradient), fg: .white)
            } else {
                smartButton(intent: SetModeIntent(mode: .always), symbol: "bolt.fill",
                            label: "Keep Awake", fill: AnyShapeStyle(Lid.yellow), fg: Lid.midnight)
            }
        }
    }

    private func smartButton<I: AppIntent>(intent: I, symbol: String, label: String,
                                           fill: AnyShapeStyle, fg: Color) -> some View {
        Button(intent: intent) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(label).font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Lock Screen

    private func lockRect(_ s: LidStatus) -> some View {
        // accessoryRectangular is ~160pt wide and non-negotiable — two full-width
        // lines that scale down beat three icon-labels that wrap vertically.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: s.statusSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .widgetAccentable()
                Text(s.headline)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(lockStats(s))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lockStats(_ s: LidStatus) -> String {
        var parts = [s.batteryText]
        if s.temp >= 0 { parts.append("\(s.temp)°C") }
        parts.append(s.lidClosed ? "lid shut" : "lid open")
        return parts.joined(separator: " · ")
    }

    private func lockInline(_ s: LidStatus) -> some View {
        Label("Mac \(s.awake ? "awake" : "sleeps") · \(s.batteryText)", systemImage: s.statusSymbol)
    }

    private func lockCircular(_ s: LidStatus) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: s.statusSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .widgetAccentable()
                Text(s.batteryText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    // MARK: States

    private var unpaired: some View {
        VStack(spacing: 7) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.title2).foregroundStyle(Lid.indigo)
            Text("Open the app to\nconnect your Mac")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var unreachable: some View {
        VStack(spacing: 7) {
            Image(systemName: "moon.haze.fill").font(.title2).foregroundStyle(Lid.indigo)
            Text("Mac unreachable")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            Button(intent: RefreshIntent()) {
                Text("Retry")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Lid.glass, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

struct LidWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LidWidget", provider: LidProvider()) { entry in
            LidWidgetView(entry: entry)
                .containerBackground(for: .widget) { Lid.background }
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
