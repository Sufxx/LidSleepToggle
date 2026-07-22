import SwiftUI

// The Settings window. Everything that needs space lives here rather than in the
// menubar popover: workload rules, safety thresholds, alert destinations, and
// the session dashboard.

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            WorkloadsTab(state: state)
                .tabItem { Label("Workloads", systemImage: "bolt.horizontal") }
            SafetyTab(state: state)
                .tabItem { Label("Safety", systemImage: "shield.lefthalf.filled") }
            AlertsTab(state: state)
                .tabItem { Label("Alerts", systemImage: "bell") }
            DashboardTab(state: state)
                .tabItem { Label("Dashboard", systemImage: "chart.bar") }
        }
        .padding(14)
        .frame(width: 520, height: 460)
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: Binding(
                            get: { state.mode }, set: { state.onSetMode($0) }
                        )) {
                            ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        Note(text: "Auto Mode keeps the Mac awake only while tracked work is running, then lets it sleep. Configure what counts as work in the Workloads tab.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Display") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Also keep the display on", isOn: binding(\.preventDisplaySleep))
                        Note(text: "Holds a display-sleep assertion so the screen stays lit too. Uses more battery. When the lid is shut the internal panel is dimmed to 0 regardless, since a covered display just wastes power.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Command Line") {
                    VStack(alignment: .leading, spacing: 8) {
                        Note(text: "Install the `lidkeep` wrapper to hold the Mac awake for exactly one command, in any mode:")
                        Text("lidkeep -- npm run build\nlidkeep --sleep -- python train.py")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        HStack {
                            Button("Install lidkeep to ~/.local/bin") { state.onInstallCLI() }
                            Spacer()
                        }
                        Note(text: "`--sleep` puts the Mac to sleep once the command exits. Make sure ~/.local/bin is on your PATH.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding<T>(_ kp: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(get: { state[keyPath: kp] },
                set: { state[keyPath: kp] = $0; state.onSettingsChanged() })
    }
}

// MARK: - Workloads

struct WorkloadsTab: View {
    @ObservedObject var state: AppState
    @State private var newName = ""
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(text: "Auto Mode keeps the Mac awake while any enabled workload is running above its CPU threshold. Claude Code is always tracked separately by session-file activity, so it survives long silent thinking pauses.")

            List {
                ForEach(Array(state.rules.enumerated()), id: \.element.id) { idx, rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { state.rules[idx].enabled },
                            set: { state.rules[idx].enabled = $0; state.onSettingsChanged() }
                        )).labelsHidden().controlSize(.small)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name).font(.system(size: 12, weight: .medium))
                            Text(rule.patterns.joined(separator: ", "))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Text("≥").font(.system(size: 10)).foregroundStyle(.tertiary)
                        TextField("", value: Binding(
                            get: { state.rules[idx].cpuThreshold },
                            set: { state.rules[idx].cpuThreshold = $0; state.onSettingsChanged() }
                        ), format: .number)
                        .frame(width: 40).controlSize(.small).multilineTextAlignment(.trailing)
                        Text("%").font(.system(size: 10)).foregroundStyle(.tertiary)

                        if !rule.builtin {
                            Button {
                                state.rules.removeAll { $0.id == rule.id }
                                state.onSettingsChanged()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                TextField("Name (e.g. Handbrake)", text: $newName)
                    .controlSize(.small).frame(width: 150)
                TextField("match text (e.g. handbrake)", text: $newPattern)
                    .controlSize(.small)
                Button("Add") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    let p = newPattern.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !p.isEmpty else { return }
                    state.rules.append(WorkloadRule(name: n, patterns: [p.lowercased()],
                                                    cpuThreshold: 20, enabled: true, builtin: false))
                    state.onSettingsChanged()
                    newName = ""; newPattern = ""
                }
                .controlSize(.small)
                .disabled(newName.isEmpty || newPattern.isEmpty)
            }
        }
    }
}

// MARK: - Safety

struct SafetyTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Battery") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Release keep-awake below")
                            Spacer()
                            Text("\(state.batteryFloor)%").monospacedDigit()
                            Stepper("", value: Binding(
                                get: { state.batteryFloor },
                                set: { state.batteryFloor = $0; state.onSettingsChanged() }
                            ), in: 5...50, step: 5).labelsHidden()
                        }
                        Toggle("Only hold while charging", isOn: binding(\.chargingOnly))
                        Note(text: "Below \(cfgInt("batteryCritical", batteryCriticalDefault))% the Mac is put to sleep outright, so a long run never ends in a hard shutdown. That floor is always on.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Thermal") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Drop the hold when critically hot", isOn: binding(\.thermalGuard))
                        Note(text: "Releases keep-awake when macOS reports critical thermal pressure, or when the hottest sensor passes \(cfgInt("tempCeiling", tempCeilingDefault))°C. Running lid-closed traps heat, so leave this on.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Away") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Sleep when offline on battery with no work", isOn: binding(\.sleepWhenOffline))
                        Note(text: "If the Mac is on battery, off the network and nothing tracked is running for \(cfgInt("offlineMinutes", offlineMinutesDefault)) minutes, it is put to sleep. Useful when you close the lid and walk out.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Watchdog") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Warn when an agent goes silent", isOn: binding(\.watchdogEnabled))
                        HStack {
                            Text("Quiet for")
                            Spacer()
                            Text("\(state.watchdogMinutes) min").monospacedDigit()
                            Stepper("", value: Binding(
                                get: { state.watchdogMinutes },
                                set: { state.watchdogMinutes = $0; state.onSettingsChanged() }
                            ), in: 5...120, step: 5).labelsHidden()
                        }
                        Note(text: "If Claude is still running but has written nothing for this long, it is usually waiting on your input rather than working.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding<T>(_ kp: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(get: { state[keyPath: kp] },
                set: { state[keyPath: kp] = $0; state.onSettingsChanged() })
    }
}

// MARK: - Alerts

struct AlertsTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Phone push (ntfy.sh)") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("topic name", text: Binding(
                            get: { state.ntfyTopic },
                            set: { state.ntfyTopic = $0; state.onSettingsChanged() }))
                        Note(text: "Install the free ntfy app, subscribe to this topic, and critical events reach your phone. Pick something unguessable — anyone who knows the topic can read it.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Webhook") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://…", text: Binding(
                            get: { state.webhookURL },
                            set: { state.webhookURL = $0; state.onSettingsChanged() }))
                        Note(text: "POSTs JSON {title, body, event, level, app} on each alert.")
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("What gets pushed") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Also push routine warnings", isOn: Binding(
                            get: { state.pushWarnings },
                            set: { state.pushWarnings = $0; state.onSettingsChanged() }))
                        Note(text: "Critical events (battery released, thermal backoff, offline sleep, stuck agent) are always pushed. Routine ones stay in the Activity Log unless you enable this.")
                        HStack {
                            Button("Send test alert") { state.onTestAlert() }
                            Spacer()
                        }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Dashboard

struct DashboardTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                stat("Sessions", "\(state.sessionCount)", "number")
                stat("Total awake", fmtDur(Int(state.totalAwake)), "clock")
                stat("Longest", fmtDur(Int(state.longestAwake)), "arrow.up.right")
            }
            Text("LAST 7 DAYS")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).kerning(0.6)

            if state.recentSessions.isEmpty {
                Spacer()
                Text("No sessions recorded yet.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(state.recentSessions) { s in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.reason.isEmpty ? "Keep Awake" : s.reason)
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("\(Self.stamp.string(from: s.start))\(s.endedBy.map { " · \($0)" } ?? "")")
                                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Text(fmtDur(Int(s.duration)))
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .onAppear { state.onRefresh() }
    }

    private func stat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
}
