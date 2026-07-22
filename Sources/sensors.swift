import Foundation
import Darwin

// Live system sensors used by the menubar chip row. Both are best-effort and
// return nil when unavailable, so the UI degrades instead of breaking.

// MARK: - CPU temperature (Apple Silicon, no root)
//
// Apple Silicon exposes thermal sensors through IOHIDEventSystem rather than the
// SMC. The functions are private, so they're resolved with dlsym and everything
// is optional — if any lookup fails we simply report no temperature.

private typealias HIDCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
private typealias HIDSetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
private typealias HIDCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
private typealias HIDServiceCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
private typealias HIDEventGetFloatValue = @convention(c) (AnyObject, Int32) -> Double
private typealias HIDServiceCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

private let kIOHIDEventTypeTemperature: Int64 = 15

final class ThermalSensors {
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var copyEvent: HIDServiceCopyEvent?
    private var getFloat: HIDEventGetFloatValue?
    private(set) var sensorNames: [String] = []

    init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let pCreate = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let pMatch = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let pServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let pEvent = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let pFloat = dlsym(iokit, "IOHIDEventGetFloatValue")
        else { return }

        let create = unsafeBitCast(pCreate, to: HIDCreate.self)
        let setMatching = unsafeBitCast(pMatch, to: HIDSetMatching.self)
        let copyServices = unsafeBitCast(pServices, to: HIDCopyServices.self)
        copyEvent = unsafeBitCast(pEvent, to: HIDServiceCopyEvent.self)
        getFloat = unsafeBitCast(pFloat, to: HIDEventGetFloatValue.self)
        let copyProp = dlsym(iokit, "IOHIDServiceClientCopyProperty")
            .map { unsafeBitCast($0, to: HIDServiceCopyProperty.self) }

        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = c
        // Usage page 0xff00 / usage 0x0005 == temperature sensors.
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005]
        setMatching(c, matching as CFDictionary)
        guard let all = copyServices(c)?.takeRetainedValue() as? [AnyObject] else { return }

        // Not every "temperature" sensor reports a temperature. On Apple Silicon
        // the `PMU tcal` entries are a fixed CALIBRATION reference that never
        // changes — taking a naive max over all sensors pins the reading to that
        // constant and it never tracks load. Keep only the die sensors.
        guard let copyProp = copyProp else { services = all; return }
        var kept: [AnyObject] = []
        var names: [String] = []
        var fallback: [AnyObject] = []
        for s in all {
            let name = (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            let lower = name.lowercased()
            if lower.contains("tcal") { continue }          // calibration, never varies
            if lower.contains("tdie") || lower.contains("tdev") {
                kept.append(s); names.append(name)
            } else {
                fallback.append(s)
            }
        }
        // Prefer die sensors; if this Mac names them differently, use whatever
        // is left after dropping the calibration entries.
        services = kept.isEmpty ? fallback : kept
        sensorNames = names
    }

    var available: Bool { !services.isEmpty && copyEvent != nil && getFloat != nil }

    // Hottest real sensor reading in °C, or nil when unreadable.
    func hottest() -> Double? {
        guard let copyEvent = copyEvent, let getFloat = getFloat, !services.isEmpty else { return nil }
        var best = 0.0
        let field = Int32(kIOHIDEventTypeTemperature << 16)
        for s in services {
            guard let ev = copyEvent(s, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, field)
            // Ignore obviously bogus sensors (some report 0 or absurd values).
            if v > best && v > 1 && v < 130 { best = v }
        }
        return best > 0 ? best : nil
    }
}

// MARK: - System-wide CPU usage
//
// Delta of mach host CPU ticks between calls. The first call has no baseline and
// returns nil.

final class CPUMonitor {
    private var prev: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    func usage() -> Int? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let user = info.cpu_ticks.0, sys = info.cpu_ticks.1
        let idle = info.cpu_ticks.2, nice = info.cpu_ticks.3
        defer { prev = (user, sys, idle, nice) }
        guard let p = prev else { return nil }

        let du = Double(user &- p.user), ds = Double(sys &- p.sys)
        let di = Double(idle &- p.idle), dn = Double(nice &- p.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return nil }
        return max(0, min(100, Int(((du + ds + dn) / total * 100).rounded())))
    }
}
