import SwiftUI

// Night-utility design language shared by the app and the widget: deep
// midnight base, warm yellow = awake/energy, soft indigo = sleep/rest.
enum Lid {
    static let midnight = Color(red: 0.043, green: 0.055, blue: 0.141)   // #0B0E24
    static let navy = Color(red: 0.078, green: 0.086, blue: 0.220)       // #141638
    static let indigo = Color(red: 0.482, green: 0.529, blue: 1.0)       // #7B87FF
    static let indigoDeep = Color(red: 0.357, green: 0.416, blue: 0.980) // #5B6AFA
    static let yellow = Color(red: 1.0, green: 0.831, blue: 0.278)       // #FFD447
    static let glass = Color.white.opacity(0.07)
    static let glassStroke = Color.white.opacity(0.10)

    static var background: LinearGradient {
        LinearGradient(colors: [midnight, navy], startPoint: .top, endPoint: .bottom)
    }
    static var sleepGradient: LinearGradient {
        LinearGradient(colors: [indigoDeep, indigo], startPoint: .leading, endPoint: .trailing)
    }
}

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
        return awake ? Lid.yellow : Lid.indigo
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
