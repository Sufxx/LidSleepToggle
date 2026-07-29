import Foundation
import CoreBluetooth

// Direct phone↔Mac link over Bluetooth LE — the PRIMARY transport for the
// companion app. The core use case ("Mac awake in a bag, sleep it from my
// phone") is a proximity scenario: the phone is within a metre of the Mac, and
// the Mac frequently has no Wi-Fi. BLE needs no internet on either side, so it
// works exactly when the internet relay can't. The ntfy relay remains as the
// fallback for genuine remote control.
//
// Protocol (same contract as the relay, same token, no new pairing):
//   service  A11D51EE-…7B01
//   cmd      write   JSON {token, action}   — validated against remoteToken
//   status   read    JSON status snapshot   — long reads served via offset
//            notify  payload if it fits in one notification, else a 1-byte
//                    nudge ("!") telling the central to re-read
//
// Security note: commands require the shared token, so a nearby stranger can't
// control the Mac. BLE traffic is not link-encrypted without OS pairing; the
// worst a sniffer could do is replay "sleep" — accepted for v1.

let bleServiceUUID = CBUUID(string: "A11D51EE-0000-4B1D-8C6E-2F5D1E6A7B01")
let bleCmdUUID = CBUUID(string: "A11D51EE-0001-4B1D-8C6E-2F5D1E6A7B01")
let bleStatusUUID = CBUUID(string: "A11D51EE-0002-4B1D-8C6E-2F5D1E6A7B01")

// Payloads at or under this size are pushed whole in a notification; larger
// ones send a nudge and the central does an ATT long read.
private let notifyLimit = 178

final class BLELink: NSObject, CBPeripheralManagerDelegate {
    weak var host: RemoteHost?
    private var manager: CBPeripheralManager?
    private var statusChar: CBMutableCharacteristic?
    private var currentStatus = Data()
    private var subscribers = 0
    private(set) var stateText = "off"
    var onStateChange: (() -> Void)?

    private var token: String { UserDefaults.standard.string(forKey: "remoteToken") ?? "" }

    func start() {
        guard manager == nil else { return }
        stateText = "starting…"
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        statusChar = nil
        subscribers = 0
        setState("off")
    }

    private func setState(_ s: String) {
        stateText = s
        log("ble: \(s)")
        onStateChange?()
    }

    // MARK: - Peripheral lifecycle

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            publishService()
        case .unauthorized:
            setState("needs Bluetooth permission (System Settings → Privacy → Bluetooth)")
        case .poweredOff:
            setState("Bluetooth is off")
        case .unsupported:
            setState("no Bluetooth hardware")
        default:
            break
        }
    }

    private func publishService() {
        guard let manager = manager else { return }
        let cmd = CBMutableCharacteristic(
            type: bleCmdUUID, properties: [.write],
            value: nil, permissions: [.writeable])
        let status = CBMutableCharacteristic(
            type: bleStatusUUID, properties: [.read, .notify],
            value: nil, permissions: [.readable])
        statusChar = status
        let service = CBMutableService(type: bleServiceUUID, primary: true)
        service.characteristics = [cmd, status]
        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [bleServiceUUID]])
        setState("advertising")
        refreshStatus()
    }

    // MARK: - Commands in

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == bleCmdUUID, let data = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            // Same HMAC envelope as the relay: a nearby stranger (or a BLE
            // sniffer) can neither forge a command nor learn the token.
            guard let (id, action) = verifyCommand(data, token: token),
                  CommandDedup.firstTime(id) else {
                log("ble: rejected write (unverified or replayed)")
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                continue
            }
            log("ble: command \(action)")
            peripheral.respond(to: request, withResult: .success)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let host = self.host else { return }
                _ = performRemoteAction(action, host: host)
                self.refreshStatus()
            }
        }
    }

    // MARK: - Status out

    // Rebuild the snapshot and notify subscribers if it changed.
    func refreshStatus() {
        guard let host = host, statusChar != nil else { return }
        var snap = host.remoteStatsSnapshot()
        snap["t"] = Int(Date().timeIntervalSince1970)
        // Keep the payload compact for BLE.
        if var reasons = snap["reasons"] as? [String], reasons.count > 4 {
            reasons = Array(reasons.prefix(4))
            snap["reasons"] = reasons
        }
        guard let json = try? JSONSerialization.data(withJSONObject: snap) else { return }
        // The timestamp changes every call; compare without it to avoid
        // notifying subscribers about nothing.
        let changed = normalized(json) != lastPlain
        lastPlain = normalized(json)
        // Sealed end-to-end: a nearby scanner that connects and reads the
        // characteristic without the token sees only ciphertext.
        guard let sealed = sealStatus(json, token: token) else { return }
        currentStatus = sealed
        guard changed, subscribers > 0, let manager = manager, let ch = statusChar else { return }
        let payload = sealed.count <= notifyLimit ? sealed : Data("!".utf8)
        manager.updateValue(payload, for: ch, onSubscribedCentrals: nil)
    }

    private var lastPlain: Data?
    private func normalized(_ d: Data) -> Data? {
        guard var obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        obj.removeValue(forKey: "t")
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == bleStatusUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        // Serve long reads: CoreBluetooth on the central side re-requests with
        // increasing offsets automatically.
        if request.offset > currentStatus.count {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = currentStatus.subdata(in: request.offset..<currentStatus.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribers += 1
        setState("phone connected")
        refreshStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { setState("advertising") }
    }
}
