import Foundation
import IOKit.pwr_mgt

// Session history for the dashboard: every stretch the Mac was held awake, why,
// and how it ended. Persisted as JSON so the numbers survive relaunches.

struct AwakeSession: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date?
    var reason: String        // what triggered it, e.g. "Claude, Docker"
    var endedBy: String?      // "work finished", "battery 18%", "timer", ...

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

final class Stats {
    private(set) var sessions: [AwakeSession] = []
    private var current: AwakeSession?

    init() { load() }

    func begin(reason: String) {
        guard current == nil else {
            // Keep the reason fresh if the mix of workloads changed.
            if current?.reason != reason { current?.reason = reason }
            return
        }
        current = AwakeSession(start: Date(), end: nil, reason: reason, endedBy: nil)
    }

    func end(by: String) {
        guard var s = current else { return }
        s.end = Date()
        s.endedBy = by
        current = nil
        // Ignore sub-10s blips so the history stays meaningful.
        guard s.duration >= 10 else { return }
        sessions.insert(s, at: 0)
        if sessions.count > 200 { sessions.removeLast(sessions.count - 200) }
        save()
    }

    var isRunning: Bool { current != nil }
    var currentSession: AwakeSession? { current }

    // Rolling 7-day figures for the dashboard.
    func recent(days: Int = 7) -> [AwakeSession] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return sessions.filter { $0.start >= cutoff }
    }
    func totalAwake(days: Int = 7) -> TimeInterval {
        recent(days: days).reduce(0) { $0 + $1.duration }
    }
    func longest(days: Int = 7) -> TimeInterval {
        recent(days: days).map { $0.duration }.max() ?? 0
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: statsPath),
              let decoded = try? JSONDecoder().decode([AwakeSession].self, from: data) else { return }
        sessions = decoded
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: URL(fileURLWithPath: statsPath))
    }
}

// MARK: - Display sleep assertion
//
// `disablesleep` stops the machine sleeping but the screen still turns off.
// "Also prevent display sleep" holds a standard IOPMAssertion instead, which
// needs no privileges.

final class DisplayAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var held = false

    func set(_ on: Bool) {
        if on && !held {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LidSleepToggle keeping display awake" as CFString,
                &id)
            if ok == kIOReturnSuccess {
                assertionID = id
                held = true
                log("display sleep assertion acquired")
            }
        } else if !on && held {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            held = false
            log("display sleep assertion released")
        }
    }
}
