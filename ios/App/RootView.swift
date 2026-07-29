import SwiftUI

struct RootView: View {
    @StateObject private var model = DashboardModel()
    @State private var showScanner = false
    @State private var showPairSheet = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if LidStore.isPaired {
                    dashboard
                } else {
                    PairEmptyState(showScanner: $showScanner, showManual: $showPairSheet)
                }
            }
            .navigationTitle("Lid Sleep")
            .toolbar {
                if LidStore.isPaired {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { Task { await model.refresh(force: true) } } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            Text("\(LidStore.topic) · \(LidStore.token.prefix(4))…")
                            Button(role: .destructive) {
                                LidStore.clear()
                                model.status = nil
                                model.ble.stop()
                            } label: {
                                Label("Unpair this Mac", systemImage: "xmark.circle")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { payload in
                    showScanner = false
                    if Pairing.handle(URL(string: payload) ?? URL(string: "x:")!) {
                        Task { await model.paired() }
                    }
                }
            }
            .sheet(isPresented: $showPairSheet) {
                ManualPairView { Task { await model.paired() } }
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.foreground() }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let s = model.status {
                    StatusHero(status: s)
                    ChipRow(status: s)
                    ModeSelector(status: s) { cmd in await model.command(cmd) }
                    SleepButton { await model.command(.sleep) }
                    if !s.reasons.isEmpty || s.holds > 0 { WorkloadCard(status: s) }
                    linkLine(s)
                } else if model.loading {
                    ProgressView("Reaching your Mac…").padding(.top, 60)
                } else {
                    UnreachableState { await model.refresh(force: true) }
                }
            }
            .padding()
        }
        .refreshable { await model.refresh(force: true) }
        .background(Color(.systemGroupedBackground))
    }

    private func linkLine(_ s: LidStatus) -> some View {
        HStack(spacing: 4) {
            switch model.link {
            case .bluetooth:
                Image(systemName: "personalhotspot").font(.caption2)
                Text("Nearby via Bluetooth · live")
            case .internet:
                Image(systemName: "network").font(.caption2)
                Text("Via internet · \(s.freshnessText)")
            case .none:
                Text(s.freshnessText)
            }
        }
        .font(.caption2)
        .foregroundStyle(model.link == .bluetooth ? Color.blue : Color(.tertiaryLabel))
    }
}

// MARK: - Model
//
// Transport arbitration: Bluetooth when the Mac is in range (works with no
// internet on either side — the in-the-bag case), the ntfy relay otherwise.

enum LinkKind { case bluetooth, internet, none }

@MainActor
final class DashboardModel: ObservableObject {
    @Published var status: LidStatus?
    @Published var loading = false
    @Published var link: LinkKind = .none
    let ble = BLEClient()
    private var ticker: Task<Void, Never>?

    func start() async {
        ble.onStatus = { [weak self] s in
            Task { @MainActor in
                self?.status = s
                self?.link = .bluetooth
                self?.loading = false
            }
        }
        ble.onLinkChange = { [weak self] connected in
            Task { @MainActor in
                guard let self = self else { return }
                if connected {
                    self.link = .bluetooth
                    self.ble.requestStatus()
                } else if self.link == .bluetooth {
                    self.link = .none
                    await self.refresh(force: false)   // fall back to the relay
                }
            }
        }
        if LidStore.isPaired { ble.start() }
        await refresh(force: true)
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.refresh(force: false)
            }
        }
    }

    func foreground() {
        guard LidStore.isPaired else { return }
        ble.start()
        Task { await refresh(force: true) }
    }

    func paired() async {
        ble.start()
        await refresh(force: true)
    }

    func refresh(force: Bool) async {
        guard LidStore.isPaired else { return }
        // Bluetooth is live-push; a read is all a manual refresh needs.
        if ble.isConnected {
            ble.requestStatus()
            return
        }
        if force { loading = status == nil }
        // Ask the Mac to publish a fresh snapshot, then read it.
        if force {
            _ = await LidClient.send(.status)
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        if let s = await LidClient.fetchStatus() {
            status = s
            if link != .bluetooth { link = .internet }
        } else if link == .internet {
            link = .none
        }
        loading = false
    }

    func command(_ cmd: LidCommand) async {
        // Prefer the direct link; it works when neither device has internet.
        if ble.isConnected, ble.send(cmd) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            ble.requestStatus()
            return
        }
        _ = await LidClient.send(cmd)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await refresh(force: false)
    }
}
