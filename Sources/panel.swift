import SwiftUI
import AppKit

// The menubar popover. Deliberately compact: anything that needs real estate
// lives in the Settings window instead, so the popover never grows tall enough
// to overflow the screen.

struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

struct MenuRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var checked: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        let content = HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 15)
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            Text(title).font(.system(size: 12, weight: checked ? .medium : .regular))
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hover && action != nil ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())

        if let action = action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
        } else {
            content
        }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(symbol: String, title: String, checked: Bool = false, action: (() -> Void)? = nil) {
        self.init(symbol: symbol, title: title, checked: checked, action: action) { EmptyView() }
    }
}

struct DisclosureRow<Content: View>: View {
    let symbol: String
    let title: String
    var badge: String? = nil
    @Binding var open: Bool
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                open.toggle()
                if open { onOpen?() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 11)).frame(width: 15)
                        .foregroundStyle(.secondary)
                    Text(title).font(.system(size: 12))
                    Spacer(minLength: 4)
                    if let b = badge {
                        Text(b)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.09), in: Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(hover ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }

            if open { content.padding(.leading, 29).padding(.trailing, 6).padding(.bottom, 2) }
        }
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var showRadar = false
    @State private var showLog = false
    @State private var showWork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chips.padding(.top, 7)
            sep
            ForEach(Mode.allCases) { m in
                MenuRow(symbol: m.symbol, title: m.title, checked: state.mode == m,
                        action: { state.onSetMode(m) }) {
                    Text(m.hint).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            sep
            quickSettings
            sep
            disclosures
            sep
            footer
        }
        .padding(9)
        .frame(width: 300)
    }

    private var sep: some View { Divider().padding(.vertical, 6) }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(state.pillColor.opacity(0.16)).frame(width: 26, height: 26)
                Image(systemName: state.vetoReason != nil
                      ? "exclamationmark.shield.fill"
                      : (state.awake ? state.mode.iconSymbol : "moon.fill"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.pillColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Lid Sleep").font(.system(size: 12, weight: .semibold))
                    Text(state.pill)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(state.pillColor)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(state.pillColor.opacity(0.15), in: Capsule())
                }
                Text(state.detail)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            Chip(symbol: state.battery.charging ? "bolt.fill" : batterySymbol,
                 text: state.battery.present ? "\(state.battery.percent)%" : "AC",
                 tint: batteryTint)
            if let t = state.tempC {
                Chip(symbol: "thermometer.medium", text: "\(Int(t.rounded()))°C", tint: tempTint(t))
            } else {
                Chip(symbol: "thermometer.medium", text: state.thermal.label)
            }
            if let c = state.cpuUsage {
                Chip(symbol: "cpu", text: "\(c)%", tint: c >= 80 ? .orange : .secondary)
            }
            Chip(symbol: state.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                 text: state.lidClosed ? "Shut" : "Open",
                 tint: state.lidClosed && state.awake ? .yellow : .secondary)
            Spacer(minLength: 0)
        }
    }

    private var batterySymbol: String {
        switch state.battery.percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        default: return "battery.100"
        }
    }
    private var batteryTint: Color {
        if state.battery.charging { return .green }
        if state.battery.percent <= cfgInt("batteryCritical", batteryCriticalDefault) { return .red }
        if state.battery.percent <= state.batteryFloor { return .orange }
        return .secondary
    }
    private func tempTint(_ t: Double) -> Color {
        switch t {
        case ..<65: return .secondary
        case ..<80: return .yellow
        case ..<92: return .orange
        default: return .red
        }
    }

    private var quickSettings: some View {
        VStack(spacing: 0) {
            MenuRow(symbol: "powerplug.fill", title: "Only While Charging",
                    checked: state.chargingOnly,
                    action: { state.chargingOnly.toggle(); state.onSettingsChanged() }) {
                if state.chargingOnly {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            MenuRow(symbol: "sun.max.fill", title: "Also Keep Display On",
                    checked: state.preventDisplaySleep,
                    action: { state.preventDisplaySleep.toggle(); state.onSettingsChanged() }) {
                if state.preventDisplaySleep {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            MenuRow(symbol: "timer", title: "Auto-stop After") {
                Picker("", selection: Binding(
                    get: { state.timerHours },
                    set: { state.timerHours = $0; state.onSettingsChanged() }
                )) {
                    Text("Off").tag(0)
                    Text("1h").tag(1); Text("2h").tag(2)
                    Text("4h").tag(4); Text("8h").tag(8)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 66).controlSize(.small)
            }
        }
    }

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: 2) {
            DisclosureRow(symbol: "bolt.horizontal.circle", title: "Active Work",
                          badge: "\(state.reasons.count)", open: $showWork,
                          onOpen: { state.onRefresh() }) {
                if state.reasons.isEmpty {
                    Text("Nothing tracked is running.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(state.workloads) { w in
                            HStack(spacing: 4) {
                                Image(systemName: "gearshape.2").font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(w.name).font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 0)
                                Text("\(Int(w.cpu))% · \(w.procs)")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                        ForEach(state.holds) { h in
                            HStack(spacing: 4) {
                                Image(systemName: "terminal").font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(h.label).font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 0)
                                Text("pid \(h.pid)").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        if state.reasons.contains("Claude") {
                            HStack(spacing: 4) {
                                Image(systemName: "brain.head.profile").font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text("Claude Code").font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 0)
                                Text(state.claudeAge >= 0 ? fmtDur(state.claudeAge) : "—")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                    }
                }
            }

            DisclosureRow(symbol: "dot.radiowaves.left.and.right",
                          title: "What's Keeping It Awake",
                          badge: "\(state.radar.count)", open: $showRadar,
                          onOpen: { state.onRefresh() }) {
                if state.radar.isEmpty {
                    Text("Nothing is blocking sleep.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(state.radar) { item in
                                HStack(spacing: 4) {
                                    Text(item.process).font(.system(size: 10, weight: .medium))
                                    Text(item.kind.replacingOccurrences(of: "PreventUserIdle", with: "")
                                                  .replacingOccurrences(of: "Prevent", with: ""))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Text(item.pid).font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                }
            }

            DisclosureRow(symbol: "list.bullet.rectangle", title: "Recent Activity", open: $showLog) {
                if state.events.isEmpty {
                    Text("No events yet.").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(state.events) { e in
                                HStack(alignment: .top, spacing: 5) {
                                    Circle().fill(e.critical ? Color.red : Color.secondary.opacity(0.5))
                                        .frame(width: 4, height: 4).padding(.top, 4)
                                    Text(e.text).font(.system(size: 10))
                                        .foregroundStyle(e.critical ? .primary : .secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Text(Self.stamp.string(from: e.at))
                                        .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                }
            }
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private var footer: some View {
        HStack(spacing: 6) {
            Button { state.onSleepNow() } label: {
                Label("Sleep Now", systemImage: "powersleep").font(.system(size: 11))
            }
            .controlSize(.small).help("Restore normal sleep and sleep the Mac now")

            Button { state.onOpenSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .controlSize(.small).keyboardShortcut(",").help("Settings")

            Button { state.onOpenLog() } label: {
                Image(systemName: "doc.text").font(.system(size: 11))
            }
            .controlSize(.small).help("Open the full log")

            Spacer()

            Button { NSApp.terminate(nil) } label: {
                Text("Quit").font(.system(size: 11))
            }
            .controlSize(.small).keyboardShortcut("q")
        }
    }
}
