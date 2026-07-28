import SwiftUI

// Presentation helpers shared by the app and the widget, so both render the
// Mac's status identically.

extension LidStatus {
    var modeTitle: String {
        switch mode {
        case "normal": return "Sleep on Lid Close"
        case "always": return "Keep Awake"
        case "auto":   return "Auto Mode"
        default:       return mode.capitalized
        }
    }
    var modeSymbol: String {
        switch mode {
        case "always": return "bolt.fill"
        case "auto":   return "bolt.badge.automatic.fill"
        default:       return "moon.fill"
        }
    }
    var headline: String {
        if !veto.isEmpty { return "Held for safety" }
        switch mode {
        case "normal": return "Sleeps on lid close"
        case "always": return awake ? "Staying awake" : "Enabling…"
        default:       return awake ? "Awake — working" : "Idle — will sleep"
        }
    }
    var subline: String {
        if !veto.isEmpty { return veto }
        if !reasons.isEmpty { return reasons.joined(separator: ", ") }
        switch mode {
        case "normal": return "Normal macOS behaviour"
        case "always": return "Held until you stop it"
        default:       return "Nothing tracked is running"
        }
    }
    var accent: Color {
        if !veto.isEmpty { return .orange }
        return awake ? .yellow : .secondary
    }
    var statusSymbol: String {
        if !veto.isEmpty { return "exclamationmark.shield.fill" }
        return awake ? modeSymbol : "moon.fill"
    }
    var batteryText: String { hasBattery ? "\(battery)%" : "AC" }
    var batterySymbol: String {
        if charging { return "battery.100.bolt" }
        switch battery {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        default:    return "battery.100"
        }
    }
    var batteryTint: Color {
        if charging { return .green }
        if battery <= 10 { return .red }
        if battery <= 20 { return .orange }
        return .secondary
    }
    var tempText: String { temp >= 0 ? "\(temp)°C" : thermal }
    var tempTint: Color {
        guard temp >= 0 else { return .secondary }
        switch temp {
        case ..<65: return .secondary
        case ..<80: return .yellow
        case ..<92: return .orange
        default:    return .red
        }
    }
    var cpuText: String { cpu >= 0 ? "\(cpu)%" : "—" }
    var lidText: String { lidClosed ? "Lid shut" : "Lid open" }
    var freshnessText: String {
        if t == 0 { return "waiting for Mac…" }
        let s = Int(age)
        if s < 60 { return "updated \(s)s ago" }
        let m = s / 60
        if m < 60 { return "updated \(m)m ago" }
        return "updated \(m / 60)h ago"
    }
}
