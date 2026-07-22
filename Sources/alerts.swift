import Foundation
import AppKit
import SystemConfiguration

// Alerting: a local macOS notification always, plus optional phone push via
// ntfy.sh and/or a generic webhook. Critical events (battery, thermal, failed
// sleep restore) are always pushed; routine ones only when "push warnings" is on.

enum AlertLevel: String {
    case routine, warning, critical
}

final class Notifier {
    // ntfy.sh topic (free, no account) and/or a webhook URL.
    var ntfyTopic: String { UserDefaults.standard.string(forKey: "ntfyTopic") ?? "" }
    var webhookURL: String { UserDefaults.standard.string(forKey: "webhookURL") ?? "" }
    var pushWarnings: Bool { UserDefaults.standard.bool(forKey: "pushWarnings") }

    func send(title: String, body: String, event: String, level: AlertLevel = .routine) {
        local(title: title, body: body)
        // Routine chatter stays in the Activity Log unless explicitly opted in.
        guard level == .critical || (level == .warning && pushWarnings) else { return }
        push(title: title, body: body, event: event, level: level)
    }

    private func local(title: String, body: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }

    private func push(title: String, body: String, event: String, level: AlertLevel) {
        let topic = ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty, let url = URL(string: "https://ntfy.sh/\(topic)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(title, forHTTPHeaderField: "Title")
            req.setValue(level == .critical ? "urgent" : "default", forHTTPHeaderField: "Priority")
            req.setValue(level == .critical ? "warning,battery" : "computer", forHTTPHeaderField: "Tags")
            req.httpBody = body.data(using: .utf8)
            URLSession.shared.dataTask(with: req) { _, _, err in
                if let err = err { log("ntfy push failed: \(err.localizedDescription)") }
            }.resume()
        }

        let hook = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hook.isEmpty, let url = URL(string: hook) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "title": title, "body": body, "event": event,
                "level": level.rawValue, "app": "LidSleepToggle",
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            URLSession.shared.dataTask(with: req) { _, _, err in
                if let err = err { log("webhook failed: \(err.localizedDescription)") }
            }.resume()
        }
    }

    // Fire-and-forget test used by the Settings window.
    func sendTest() {
        send(title: "LidSleepToggle test",
             body: "Alerts are wired up correctly.",
             event: "test", level: .critical)
    }
}

// Cheap reachability check for the "sleep when offline" safety rule.
func isOnline() -> Bool {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    guard let reach = withUnsafePointer(to: &addr, { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            SCNetworkReachabilityCreateWithAddress(nil, $0)
        }
    }) else { return true }   // assume online rather than sleeping the Mac on a false negative

    var flags = SCNetworkReachabilityFlags()
    guard SCNetworkReachabilityGetFlags(reach, &flags) else { return true }
    let reachable = flags.contains(.reachable)
    let needsConnection = flags.contains(.connectionRequired)
    return reachable && !needsConnection
}
