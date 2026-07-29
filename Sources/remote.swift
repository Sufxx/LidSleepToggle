import Foundation

// Remote control over ntfy.sh, so the iPhone app / widget can see status and
// send commands while the Mac is awake in a bag.
//
// Two topics under one random base name:
//   <base>-cmd    the Mac SUBSCRIBES; the phone publishes commands here
//   <base>-stats  the Mac PUBLISHES a status snapshot; the phone reads it
//
// The base name is unguessable, and every command must carry a shared secret
// token, so knowing the topic alone is not enough to control the Mac. Both are
// generated on first enable and shown in Settings for pairing.
//
// The Mac can only be reached while it is awake (which is exactly the "keep
// awake in a bag" case). Remote SLEEP always works; remote wake does not,
// because a sleeping Mac isn't listening.

protocol RemoteHost: AnyObject {
    func remoteSetMode(_ m: Mode)
    func remoteSleepNow()
    func remoteStatsSnapshot() -> [String: Any]
}

final class RemoteControl: NSObject, URLSessionDataDelegate {
    weak var host: RemoteHost?
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var running = false
    private var reconnectDelay: TimeInterval = 2
    private var lastStatsPush = Date(timeIntervalSince1970: 0)
    // ntfy is at-least-once: the same message can arrive more than once across
    // reconnects. Track recent IDs so a command runs exactly once.
    private var seenIDs: [String] = []
    private var seenSet = Set<String>()

    var enabled: Bool { cfgBool("remoteEnabled", false) }
    var base: String { UserDefaults.standard.string(forKey: "remoteTopic") ?? "" }
    var token: String { UserDefaults.standard.string(forKey: "remoteToken") ?? "" }
    var cmdTopic: String { base + "-cmd" }
    var statsTopic: String { base + "-stats" }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0            // no timeout on the stream
        cfg.timeoutIntervalForResource = 0
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // Create a random topic + token the first time remote control is turned on.
    static func ensureCredentials() {
        let d = UserDefaults.standard
        if (d.string(forKey: "remoteTopic") ?? "").isEmpty {
            d.set("lidsleep-" + randomToken(10), forKey: "remoteTopic")
        }
        if (d.string(forKey: "remoteToken") ?? "").isEmpty {
            d.set(randomToken(16), forKey: "remoteToken")
        }
    }

    private static func randomToken(_ n: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    func start() {
        guard enabled, !base.isEmpty, !running else { return }
        running = true
        reconnectDelay = 2
        connect()
        log("remote: started on topic \(base)")
        pushStats(force: true)
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        log("remote: stopped")
    }

    // Rebuild the session on restart. Reusing a session whose delegate callbacks
    // are mid-flight during a rapid stop/start can fire a resume on a torn-down
    // task (observed as a SIGSEGV in NSURLSessionTask resume). A fresh session
    // guarantees no stale in-flight callbacks touch new state.
    func restart() {
        stop()
        session.invalidateAndCancel()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0
        cfg.timeoutIntervalForResource = 0
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        if enabled { start() }
    }

    // MARK: - Command stream (subscribe)

    private func connect() {
        guard running, let url = URL(string: "https://ntfy.sh/\(cmdTopic)/json") else { return }
        buffer.removeAll(keepingCapacity: true)
        // Streaming GET: ntfy holds the connection open and pushes one JSON
        // object per line as commands arrive.
        task = session.dataTask(with: url)
        task?.resume()
    }

    // ntfy's /json endpoint streams one JSON object per line.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handleLine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard running else { return }
        // Reconnect with capped backoff; ntfy also drops idle streams periodically.
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.running else { return }
            self.connect()
        }
    }

    private func handleLine(_ line: Data) {
        guard let env = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // Skip keepalive / open events.
        guard (env["event"] as? String) == "message" else {
            if env["event"] != nil { reconnectDelay = 2 }   // healthy stream, reset backoff
            return
        }
        reconnectDelay = 2

        // Deduplicate: skip a message ID we've already acted on.
        if let id = env["id"] as? String {
            if seenSet.contains(id) { return }
            seenSet.insert(id); seenIDs.append(id)
            if seenIDs.count > 200 { let old = seenIDs.removeFirst(); seenSet.remove(old) }
        }

        guard let body = env["message"] as? String,
              let inner = body.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] else { return }

        guard (cmd["token"] as? String) == token, !token.isEmpty else {
            log("remote: rejected command with bad/missing token")
            return
        }
        guard let action = cmd["action"] as? String else { return }
        log("remote: command \(action)")
        DispatchQueue.main.async { [weak self] in self?.dispatch(action) }
    }

    private func dispatch(_ action: String) {
        guard let host = host else { return }
        switch action {
        case "sleep", "sleepnow":
            host.remoteSleepNow()
        case "mode:normal":
            host.remoteSetMode(.normal)
        case "mode:always":
            host.remoteSetMode(.always)
        case "mode:auto":
            host.remoteSetMode(.auto)
        case "status":
            break   // just want a fresh snapshot
        default:
            log("remote: unknown action \(action)")
            return
        }
        pushStats(force: true)
    }

    // MARK: - Stats (publish)

    // Coalesced so we never hammer ntfy: forced pushes (command replies, mode
    // changes) always go; passive ticks are rate-limited.
    func pushStats(force: Bool) {
        guard enabled, !base.isEmpty, let host = host else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastStatsPush) < 25 { return }
        lastStatsPush = now

        var snap = host.remoteStatsSnapshot()
        snap["t"] = Int(now.timeIntervalSince1970)
        guard let payload = try? JSONSerialization.data(withJSONObject: snap),
              let url = URL(string: "https://ntfy.sh/\(statsTopic)") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Retain only the latest snapshot server-side; the phone polls for it.
        req.setValue("1", forHTTPHeaderField: "X-Cache")
        req.setValue("no", forHTTPHeaderField: "X-Firebase")
        req.httpBody = payload
        session.dataTask(with: req).resume()
    }
}
