import Foundation
import CryptoKit

// End-to-end crypto for the phone link. The relay servers are untrusted dumb
// pipes: they never see the token, can't forge commands, and can't read status.
//
//   Commands  {id, ts, action, mac} where mac = hex(HMAC-SHA256(token, "id|ts|action"))
//             — the token itself is never transmitted. Replay is blocked by the
//             id dedup plus a freshness window on ts.
//   Status    AES-256-GCM sealed with key = SHA256(token); binary over BLE,
//             base64 over the relay.
//
// MUST stay in sync with ios/Shared/LidCrypto.swift.

let commandFreshnessWindow: TimeInterval = 300

private func statusKey(_ token: String) -> SymmetricKey {
    SymmetricKey(data: SHA256.hash(data: Data(token.utf8)))
}

func signCommand(token: String, id: String, ts: Int, action: String) -> String {
    let msg = Data("\(id)|\(ts)|\(action)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: Data(token.utf8)))
    return mac.map { String(format: "%02x", $0) }.joined()
}

// Parses and authenticates a command envelope. Returns the action only when the
// signature verifies and the timestamp is fresh. Plaintext {token, action}
// envelopes are deliberately NOT accepted — no downgrade path.
func verifyCommand(_ data: Data, token: String, now: Date = Date()) -> (id: String, action: String)? {
    guard !token.isEmpty,
          let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = cmd["id"] as? String, !id.isEmpty,
          let ts = cmd["ts"] as? Int,
          let action = cmd["action"] as? String,
          let mac = cmd["mac"] as? String
    else { return nil }
    guard abs(now.timeIntervalSince1970 - Double(ts)) <= commandFreshnessWindow else { return nil }
    let msg = Data("\(id)|\(ts)|\(action)".utf8)
    guard let macData = Data(hexString: mac),
          HMAC<SHA256>.isValidAuthenticationCode(macData, authenticating: msg,
                                                 using: SymmetricKey(data: Data(token.utf8)))
    else { return nil }
    return (id, action)
}

func sealStatus(_ json: Data, token: String) -> Data? {
    guard !token.isEmpty, let sealed = try? AES.GCM.seal(json, using: statusKey(token)) else { return nil }
    return sealed.combined
}

func openStatus(_ blob: Data, token: String) -> Data? {
    guard !token.isEmpty,
          let box = try? AES.GCM.SealedBox(combined: blob),
          let plain = try? AES.GCM.open(box, using: statusKey(token)) else { return nil }
    return plain
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }
}
