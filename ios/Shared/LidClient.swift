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
    // Custom relay override (from the pairing QR). Empty = use the built-in
    // redundant pair, so no single blocked host kills the internet path.
    static var server: String {
        get { d.string(forKey: "server") ?? "" }
        set { d.set(newValue, forKey: "server") }
    }
    static var servers: [String] {
        server.isEmpty ? ["https://ntfy.sh", "https://ntfy.envs.net"] : [server]
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
    // Queries every relay in parallel and returns the freshest snapshot any of
    // them holds — one blocked or stale server can't blind the app.
    static func fetchStatus() async -> LidStatus? {
        let topic = LidStore.topic, token = LidStore.token
        guard !topic.isEmpty else { return nil }
        return await withTaskGroup(of: LidStatus?.self) { group in
            for server in LidStore.servers {
                group.addTask { await fetchStatus(server: server, topic: topic, token: token) }
            }
            var best: LidStatus?
            for await s in group {
                if let s = s, s.t > (best?.t ?? -1) { best = s }
            }
            return best
        }
    }

    // `poll=1` returns the cached message immediately instead of holding the
    // connection open; the last envelope wins because the Mac retains only its
    // most recent snapshot. The body is AES-GCM ciphertext, base64-encoded.
    private static func fetchStatus(server: String, topic: String, token: String) async -> LidStatus? {
        guard let url = URL(string: "\(server)/\(topic)-stats/json?poll=1&since=all") else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: req)
            var latest: LidStatus?
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)),
                      env.event == "message",
                      let msg = env.message,
                      let blob = Data(base64Encoded: msg),
                      let plain = openStatus(blob, token: token),
                      let s = try? JSONDecoder().decode(LidStatus.self, from: plain)
                else { continue }
                latest = s
            }
            return latest
        } catch {
            return nil
        }
    }

    // Publishes one signed envelope to every relay (the Mac deduplicates by
    // envelope id). The token itself never crosses a relay.
    @discardableResult
    static func send(_ command: LidCommand) async -> Bool {
        let topic = LidStore.topic, token = LidStore.token
        guard !topic.isEmpty, !token.isEmpty,
              let body = signedCommandBody(token: token, action: command.rawValue) else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            for server in LidStore.servers {
                group.addTask {
                    guard let url = URL(string: "\(server)/\(topic)-cmd") else { return false }
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
            }
            var ok = false
            for await r in group where r { ok = true }
            return ok
        }
    }

    private struct Envelope: Decodable {
        let event: String
        let message: String?
    }
}
