import SwiftUI

// The dashboard's building blocks.

struct StatusHero: View {
    let status: LidStatus
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(status.accent.opacity(0.18)).frame(width: 54, height: 54)
                Image(systemName: status.statusSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(status.accent == .secondary ? Color.secondary : status.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(status.headline).font(.title3.weight(.semibold))
                Text(status.subline).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ChipRow: View {
    let status: LidStatus
    var body: some View {
        HStack(spacing: 8) {
            chip(status.batterySymbol, status.batteryText, status.batteryTint, "Battery")
            chip("thermometer.medium", status.tempText, status.tempTint, "Temp")
            chip("cpu", status.cpuText, status.cpu >= 80 ? .orange : .secondary, "CPU")
            chip(status.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                 status.lidClosed ? "Shut" : "Open",
                 status.lidClosed && status.awake ? .yellow : .secondary, "Lid")
        }
    }
    private func chip(_ symbol: String, _ value: String, _ tint: Color, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ModeOption: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let cmd: LidCommand
}

struct ModeSelector: View {
    let status: LidStatus
    let onPick: (LidCommand) async -> Void
    @State private var busy: String?

    private let modes: [ModeOption] = [
        ModeOption(id: "normal", title: "Sleep on Lid Close", symbol: "moon.fill", cmd: .modeNormal),
        ModeOption(id: "always", title: "Keep Awake", symbol: "bolt.fill", cmd: .modeAlways),
        ModeOption(id: "auto", title: "Auto Mode", symbol: "bolt.badge.automatic.fill", cmd: .modeAuto),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(modes) { m in
                row(for: m)
                if m.id != modes.last?.id { Divider().padding(.leading, 44) }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func row(for m: ModeOption) -> some View {
        let selected = status.mode == m.id
        Button {
            busy = m.id
            Task { await onPick(m.cmd); busy = nil }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(m.title).foregroundStyle(.primary)
                Spacer()
                if busy == m.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: m.symbol).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SleepButton: View {
    let action: () async -> Void
    @State private var busy = false
    var body: some View {
        Button {
            busy = true
            Task { await action(); busy = false }
        } label: {
            HStack {
                if busy { ProgressView().tint(.white) }
                else { Image(systemName: "powersleep") }
                Text(busy ? "Sleeping…" : "Sleep My Mac Now").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .disabled(busy)
    }
}

struct WorkloadCard: View {
    let status: LidStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KEEPING IT AWAKE").font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary).kerning(0.6)
            ForEach(status.reasons, id: \.self) { r in
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.fill").font(.caption).foregroundStyle(.yellow)
                    Text(r).font(.subheadline)
                    Spacer()
                }
            }
            if status.holds > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary)
                    Text("\(status.holds) held command\(status.holds == 1 ? "" : "s")").font(.subheadline)
                    Spacer()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct UnreachableState: View {
    let retry: () async -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.orange)
            Text("Can't reach your Mac").font(.headline)
            Text("If you're next to the Mac, keep Bluetooth on — the direct link connects in a few seconds, no internet needed. From farther away it needs both devices online. A Mac that's already asleep can't be reached at all.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await retry() } }.buttonStyle(.bordered)
        }
        .padding().padding(.top, 40)
    }
}
