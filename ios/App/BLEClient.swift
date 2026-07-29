import Foundation
import CoreBluetooth

// Direct Bluetooth link to the Mac — the primary transport. Works with zero
// internet on either side, which is exactly the "Mac closed in a bag" case the
// app exists for. The ntfy relay in LidClient is the fallback for genuine
// remote control. Same command schema and token on both paths.
//
// Lives in the app target only: widget extensions cannot use CoreBluetooth,
// so widget buttons stay on the relay.

let bleServiceUUID = CBUUID(string: "A11D51EE-0000-4B1D-8C6E-2F5D1E6A7B01")
let bleCmdUUID = CBUUID(string: "A11D51EE-0001-4B1D-8C6E-2F5D1E6A7B01")
let bleStatusUUID = CBUUID(string: "A11D51EE-0002-4B1D-8C6E-2F5D1E6A7B01")

final class BLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatus: ((LidStatus) -> Void)?
    var onLinkChange: ((Bool) -> Void)?
    private(set) var isConnected = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfReady()
        }
    }

    func stop() {
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        setConnected(false)
    }

    private func scanIfReady() {
        guard let c = central, c.state == .poweredOn, peripheral == nil else { return }
        c.scanForPeripherals(withServices: [bleServiceUUID], options: nil)
    }

    private func setConnected(_ v: Bool) {
        guard isConnected != v else { return }
        isConnected = v
        onLinkChange?(v)
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scanIfReady()
        } else {
            // .unsupported (simulator), .poweredOff, .unauthorized — the relay
            // fallback carries the app; nothing to do here.
            setConnected(false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([bleServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        retryLater()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        retryLater()
    }

    private func retryLater() {
        peripheral = nil
        cmdChar = nil
        statusChar = nil
        setConnected(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scanIfReady()
        }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == bleServiceUUID }) else { return }
        peripheral.discoverCharacteristics([bleCmdUUID, bleStatusUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == bleCmdUUID { cmdChar = ch }
            if ch.uuid == bleStatusUUID { statusChar = ch }
        }
        guard let status = statusChar, cmdChar != nil else { return }
        peripheral.setNotifyValue(true, for: status)
        peripheral.readValue(for: status)
        setConnected(true)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == bleStatusUUID,
              let data = characteristic.value, !data.isEmpty else { return }
        if let s = try? JSONDecoder().decode(LidStatus.self, from: data) {
            onStatus?(s)
        } else if data.count < 8 {
            // A nudge: the full snapshot didn't fit in one notification. A read
            // assembles the whole value (CoreBluetooth does long reads itself).
            peripheral.readValue(for: characteristic)
        }
    }

    // MARK: - Commands

    @discardableResult
    func send(_ command: LidCommand) -> Bool {
        guard isConnected, let p = peripheral, let ch = cmdChar else { return false }
        let payload = ["token": LidStore.token, "action": command.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        p.writeValue(data, for: ch, type: .withResponse)
        return true
    }

    func requestStatus() {
        guard let p = peripheral, let ch = statusChar else { return }
        p.readValue(for: ch)
    }
}
