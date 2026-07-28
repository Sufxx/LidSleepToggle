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
                            Button(role: .destructive) {
                                LidStore.clear(); model.status = nil
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
                        Task { await model.refresh(force: true) }
                    }
                }
            }
            .sheet(isPresented: $showPairSheet) {
                ManualPairView { Task { await model.refresh(force: true) } }
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh(force: true) } }
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
                    Text(s.freshnessText)
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if model.loading {
                    ProgressView("Reaching your Mac…").padding(.top, 60)
                } else {
                    UnreachableState { await model.command(.status) }
                }
            }
            .padding()
        }
        .refreshable { await model.refresh(force: true) }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Model

@MainActor
final class DashboardModel: ObservableObject {
    @Published var status: LidStatus?
    @Published var loading = false
    private var ticker: Task<Void, Never>?

    func start() async {
        await refresh(force: true)
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.refresh(force: false)
            }
        }
    }

    func refresh(force: Bool) async {
        guard LidStore.isPaired else { return }
        if force { loading = status == nil }
        // Ask the Mac to publish a fresh snapshot, then read it.
        if force { _ = await LidClient.send(.status) ; try? await Task.sleep(nanoseconds: 900_000_000) }
        if let s = await LidClient.fetchStatus() { status = s }
        loading = false
    }

    func command(_ cmd: LidCommand) async {
        _ = await LidClient.send(cmd)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await refresh(force: false)
    }
}
