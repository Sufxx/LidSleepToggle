import Foundation
import IOKit.ps

// MARK: - System readings

struct Battery {
    var percent: Int = 100
    var charging: Bool = true
    var present: Bool = false
}

func batteryInfo() -> Battery {
    var b = Battery()
    guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return b }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any] else { continue }
        guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
        b.present = true
        b.percent = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : cur
        b.charging = (d[kIOPSPowerSourceStateKey] as? String ?? "") == kIOPSACPowerValue
        return b
    }
    return b
}

enum ThermalLevel: Int {
    case normal = 0, warm = 1, hot = 2, critical = 3
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warm: return "Warm"
        case .hot: return "Hot"
        case .critical: return "Critical"
        }
    }
}

func thermalLevel() -> ThermalLevel {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return .normal
    case .fair: return .warm
    case .serious: return .hot
    case .critical: return .critical
    @unknown default: return .normal
    }
}

struct AwakeItem: Identifiable {
    let id = UUID()
    let process: String
    let pid: String
    let kind: String
}

// Parses `pmset -g assertions` into the processes actively blocking sleep.
func awakeRadar() -> [AwakeItem] {
    let out = run(pmsetPath, ["-g", "assertions"]).output
    let blocking = ["PreventUserIdleSystemSleep", "PreventSystemSleep",
                    "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep"]
    var items: [AwakeItem] = []
    var seen = Set<String>()
    for raw in out.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("pid ") else { continue }
        guard let kind = blocking.first(where: { line.contains($0) }) else { continue }
        let afterPid = line.dropFirst(4)
        guard let paren = afterPid.firstIndex(of: "("), let close = afterPid.firstIndex(of: ")") else { continue }
        let pid = String(afterPid[afterPid.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        let proc = String(afterPid[afterPid.index(after: paren)..<close])
        let key = proc + kind
        if seen.contains(key) { continue }
        seen.insert(key)
        items.append(AwakeItem(process: proc, pid: pid, kind: kind))
    }
    return items
}

