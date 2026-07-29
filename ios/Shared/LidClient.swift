import Foundation

// Shared between the app and the widget. Talks to the same ntfy topics the Mac
// uses: reads the latest status snapshot, and posts token-signed commands.
//
// Pairing details live in an App Group so the widget extension can read them
// without its own onboarding.

enum LidStore {
    static let suite = "group.com.sufwan.lidsleeptoggle"
    private static var d: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    static var topic: String {
        get { d.string(forKey: "topic") ?? "" }
        set { d.set(newValue, forKey: "topic") }
    }
    static var token: String {
        get { d.string(forKey: "token") ?? "" }
        set { d.set(newValue, forKey: "token") }
    }
    static var macName: String {
        get { d.string(forKey: "macName") ?? "Mac" }
        set { d.set(newValue, forKey: "macName") }
    }
    // Relay server, configurable so a blocked/down public instance isn't fatal.
    // Empty means the default.
    static var server: String {
        get {
            let s = d.string(forKey: "server") ?? ""
            return s.isEmpty ? "https://ntfy.sh" : s
        }
        set { d.set(newValue, forKey: "server") }
    }
    static var isPaired: Bool { !topic.isEmpty && !token.isEmpty }

    static func clear() {
        d.removeObject(forKey: "topic")
        d.removeObject(forKey: "token")
        d.removeObject(forKey: "macName")
    }
}

// The Mac's status snapshot. Field names mirror remoteStatsSnapshot() on macOS.
struct LidStatus: Codable, Equatable {
    var mode: String
    var awake: Bool
    var veto: String
    var battery: Int
    var charging: Bool
    var hasBattery: Bool
    var temp: Int          // °C, -1 when unavailable
    var cpu: Int           // %, -1 when unavailable
    var thermal: String
    var lidClosed: Bool
    var reasons: [String]
    var holds: Int
    var host: String
    var t: Int             // unix seconds when the Mac published this

    var age: TimeInterval { max(0, Date().timeIntervalSince1970 - Double(t)) }

    // Fresh if the Mac reported within the last few minutes.
    var isFresh: Bool { age < 300 }

    static let placeholder = LidStatus(
        mode: "auto", awake: true, veto: "", battery: 72, charging: false,
        hasBattery: true, temp: 46, cpu: 31, thermal: "Normal", lidClosed: true,
        reasons: ["Claude"], holds: 0, host: "MacBook Pro", t: 0)
}

enum LidCommand: String {
    case sleep, modeNormal = "mode:normal", modeAlways = "mode:always"
    case modeAuto = "mode:auto", status
}

enum LidClient {
    private static var base: String { LidStore.server }

    // Reads the latest cached status the Mac published. `poll=1` returns the
    // cached message immediately instead of holding the connection open.
    static func fetchStatus() async -> LidStatus? {
        let topic = LidStore.topic
        guard !topic.isEmpty,
              let url = URL(string: "\(base)/\(topic)-stats/json?poll=1&since=all") else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: req)
            // ntfy returns newline-delimited JSON envelopes; the last message
            // wins because the Mac retains only its most recent snapshot.
            var latest: LidStatus?
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)),
                      env.event == "message",
                      let msg = env.message,
                      let s = try? JSONDecoder().decode(LidStatus.self, from: Data(msg.utf8))
                else { continue }
                latest = s
            }
            return latest
        } catch {
            return nil
        }
    }

    @discardableResult
    static func send(_ command: LidCommand) async -> Bool {
        let topic = LidStore.topic, token = LidStore.token
        guard !topic.isEmpty, !token.isEmpty,
              let url = URL(string: "\(base)/\(topic)-cmd") else { return false }
        let payload = ["token": token, "action": command.rawValue]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private struct Envelope: Decodable {
        let event: String
        let message: String?
    }
}
