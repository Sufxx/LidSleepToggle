import SwiftUI

// The dashboard's building blocks — night-utility styling: layered midnight
// background, glass cards, a glowing status orb, yellow for awake and indigo
// for sleep.

// MARK: - Atmosphere

struct NightBackground: View {
    var awake: Bool

    var body: some View {
        ZStack {
            Lid.background
            // Indigo bloom anchored top-leading; warm bloom fades in when the
            // Mac is being held awake.
            RadialGradient(colors: [Lid.indigo.opacity(0.28), .clear],
                           center: .init(x: 0.1, y: 0.0), startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Lid.yellow.opacity(awake ? 0.16 : 0.0), .clear],
                           center: .init(x: 0.95, y: 0.1), startRadius: 5, endRadius: 380)
                .animation(.easeInOut(duration: 1.2), value: awake)
            // Faint star field.
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 7)
                for _ in 0..<46 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height * 0.6
                    let r = 0.4 + rng.next() * 0.9
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(.white.opacity(0.06 + rng.next() * 0.10)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// Deterministic so the stars don't re-scatter every render.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}

private struct GlassCard: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(Lid.glass, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Lid.glassStroke, lineWidth: 0.5))
    }
}

extension View {
    func glassCard(radius: CGFloat = 18) -> some View { modifier(GlassCard(radius: radius)) }
}

// MARK: - Hero

struct StatusHero: View {
    let status: LidStatus
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                // Glow halo, breathing while awake.
                Circle()
                    .fill(status.accent.opacity(0.16))
                    .frame(width: 132, height: 132)
                    .blur(radius: 22)
                    .scaleEffect(breathe ? 1.12 : 0.94)
                Circle()
                    .fill(status.accent.opacity(0.14))
                    .frame(width: 96, height: 96)
                Circle()
                    .strokeBorder(status.accent.opacity(0.5), lineWidth: 1.2)
                    .frame(width: 96, height: 96)
                Image(systemName: status.statusSymbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(status.accent)
                    .shadow(color: status.accent.opacity(0.8), radius: 14)
            }
            .frame(height: 138)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            VStack(spacing: 4) {
                Text(status.headline)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(status.subline)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

// MARK: - Chips

struct ChipRow: View {
    let status: LidStatus
    var body: some View {
        HStack(spacing: 9) {
            chip(status.batterySymbol, status.batteryText,
                 status.charging ? .green : status.batteryTint, "Battery")
            chip("thermometer.medium", status.tempText, status.tempTint, "Temp")
            chip("cpu", status.cpuText, status.cpu >= 80 ? .orange : .white.opacity(0.7), "CPU")
            chip(status.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                 status.lidClosed ? "Shut" : "Open",
                 status.lidClosed && status.awake ? Lid.yellow : .white.opacity(0.7), "Lid")
        }
    }

    private func chip(_ symbol: String, _ value: String, _ tint: Color, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .glassCard(radius: 15)
    }
}

// MARK: - Mode cards

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
        ModeOption(id: "normal", title: "Sleep on\nClose", symbol: "moon.fill", cmd: .modeNormal),
        ModeOption(id: "always", title: "Keep\nAwake", symbol: "bolt.fill", cmd: .modeAlways),
        ModeOption(id: "auto", title: "Auto\nMode", symbol: "bolt.badge.automatic.fill", cmd: .modeAuto),
    ]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(modes) { m in card(m) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: status.mode)
    }

    private func card(_ m: ModeOption) -> some View {
        let selected = status.mode == m.id
        let accent: Color = m.id == "normal" ? Lid.indigo : Lid.yellow
        return Button {
            guard busy == nil, !selected else { return }
            busy = m.id
            Task { await onPick(m.cmd); busy = nil }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    if busy == m.id {
                        ProgressView().controlSize(.small).tint(selected ? Lid.midnight : .white)
                    } else {
                        Image(systemName: m.symbol)
                            .font(.system(size: 19, weight: .semibold))
                    }
                }
                .frame(height: 22)
                Text(m.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)
            }
            .foregroundStyle(selected ? Lid.midnight : .white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                selected ? AnyShapeStyle(accent) : AnyShapeStyle(Lid.glass),
                in: RoundedRectangle(cornerRadius: 17)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(selected ? accent : Lid.glassStroke, lineWidth: 0.5)
            )
            .shadow(color: selected ? accent.opacity(0.35) : .clear, radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sleep button

struct SleepButton: View {
    let action: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task { await action(); busy = false }
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                else { Image(systemName: "moon.zzz.fill").font(.system(size: 16, weight: .semibold)) }
                Text(busy ? "Sleeping…" : "Sleep My Mac Now")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Lid.sleepGradient, in: RoundedRectangle(cornerRadius: 17))
            .shadow(color: Lid.indigoDeep.opacity(0.45), radius: 16, y: 6)
        }
        .disabled(busy)
    }
}

// MARK: - Workloads

struct WorkloadCard: View {
    let status: LidStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("KEEPING IT AWAKE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .kerning(1.0)
            ForEach(status.reasons, id: \.self) { r in
                HStack(spacing: 9) {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 11)).foregroundStyle(Lid.yellow)
                    Text(r)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
            }
            if status.holds > 0 {
                HStack(spacing: 9) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11)).foregroundStyle(Lid.indigo)
                    Text("\(status.holds) held command\(status.holds == 1 ? "" : "s")")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Unreachable

struct UnreachableState: View {
    let retry: () async -> Void
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: "moon.haze.fill")
                .font(.system(size: 44)).foregroundStyle(Lid.indigo)
                .shadow(color: Lid.indigo.opacity(0.6), radius: 16)
            Text("Can't reach your Mac")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("If you're next to it, keep Bluetooth on — the direct link connects in seconds, no internet needed. From farther away both devices need to be online. A Mac that's already asleep can't be reached at all.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button {
                Task { await retry() }
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .glassCard(radius: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }
}
