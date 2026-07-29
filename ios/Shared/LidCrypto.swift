import Foundation
import CryptoKit

// End-to-end crypto for the phone link — the relay servers are untrusted dumb
// pipes. MUST stay in sync with Sources/lidcrypto.swift on the Mac side.
//
//   Commands  {id, ts, action, mac} where mac = hex(HMAC-SHA256(token, "id|ts|action"))
//   Status    AES-256-GCM sealed with key = SHA256(token)

private func statusKey(_ token: String) -> SymmetricKey {
    SymmetricKey(data: SHA256.hash(data: Data(token.utf8)))
}

func signCommand(token: String, id: String, ts: Int, action: String) -> String {
    let msg = Data("\(id)|\(ts)|\(action)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: Data(token.utf8)))
    return mac.map { String(format: "%02x", $0) }.joined()
}

func signedCommandBody(token: String, action: String) -> Data? {
    let id = UUID().uuidString
    let ts = Int(Date().timeIntervalSince1970)
    let payload: [String: Any] = [
        "id": id, "ts": ts, "action": action,
        "mac": signCommand(token: token, id: id, ts: ts, action: action),
    ]
    return try? JSONSerialization.data(withJSONObject: payload)
}

func openStatus(_ blob: Data, token: String) -> Data? {
    guard !token.isEmpty,
          let box = try? AES.GCM.SealedBox(combined: blob),
          let plain = try? AES.GCM.open(box, using: statusKey(token)) else { return nil }
    return plain
}
