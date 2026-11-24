import CoreBluetooth
import Foundation

/// Direct link to the projector's built-in (firmware) receiver — the one Lumina Go drives.
/// Because that receiver is a system app, the firmware does not disable it, so navigation and
/// focus work where BeamDeck's own accessibility service gets switched off. See LUMINA_PROTOCOL.md.
@MainActor
final class LuminaLink: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, scanning, connecting, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nearby: [NearbyProjector] = []
    @Published private(set) var connectedName: String?

    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmd: CBCharacteristic?
    private var negotiatedMtu = 23
    private var wantsScan = false
    private let serviceId = CBUUID(string: "FFF0")
    private let cmdId = CBUUID(string: "FFF1")
    private let statusId = CBUUID(string: "FFF2")
    private let lastKey = "lastLumina"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var connected: Bool { phase == .ready }
    var peripheralId: String? { peripheral?.identifier.uuidString }

    func scan() {
        wantsScan = true
        guard central.state == .poweredOn else { return }
        nearby.removeAll()
        if connected { return }
        phase = .scanning
        // Some firmwares advertise the name but not the service UUID, so scan broadly and filter by name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ id: UUID) {
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = target
        target.delegate = self
        connectedName = target.name ?? nearby.first { $0.id == id }?.name
        phase = .connecting
        central.connect(target)
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        cmd = nil
        UserDefaults.standard.removeObject(forKey: lastKey)
        phase = .idle
    }

    // MARK: sending

    /// One 2-byte [category, action] command, or a longer mouse packet.
    func send(_ bytes: [UInt8]) {
        guard let peripheral, let cmd else { return }
        peripheral.writeValue(Data(bytes), for: cmd, type: .withResponse)
    }

    /// UTF-8 text, chunked with the 0xFF prefix and terminated by 0xFE, exactly as the receiver expects.
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        let chunk = max(1, negotiatedMtu - 4)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            send([0xFF] + bytes[offset..<end])
            offset = end
        }
        send([0xFE])
    }

    private func discover(_ advertisement: [String: Any], fallback name: String?) -> Bool {
        if let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], services.contains(serviceId) {
            return true
        }
        let shown = (advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? name
        return shown?.hasPrefix("HTC_Projector") == true
    }
}

extension LuminaLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central.state == .poweredOn else { return }
            if let last = UserDefaults.standard.string(forKey: lastKey), let id = UUID(uuidString: last) {
                connect(id)
            } else if wantsScan {
                scan()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard discover(advertisementData, fallback: peripheral.name) else { return }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Проєктор"
            if let index = nearby.firstIndex(where: { $0.id == peripheral.identifier }) {
                nearby[index].rssi = RSSI.intValue
            } else {
                nearby.append(NearbyProjector(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            negotiatedMtu = peripheral.maximumWriteValueLength(for: .withResponse) + 3
            peripheral.discoverServices([serviceId])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { phase = .failed("Не вдалося під’єднатися до проєктора.") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            cmd = nil
            phase = .connecting
            central.connect(peripheral) // stay attached, like the stock remote
        }
    }
}

extension LuminaLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
                phase = .failed("Це не той приймач. Оновіть програму проєктора.")
                return
            }
            peripheral.discoverCharacteristics([cmdId, statusId], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == cmdId { cmd = characteristic }
                if characteristic.uuid == statusId { peripheral.setNotifyValue(true, for: characteristic) }
            }
            if cmd != nil {
                if let id = peripheralId { UserDefaults.standard.set(id, forKey: lastKey) }
                phase = .ready
                onReady?()
            }
        }
    }
}

/// Maps the remote's key names to the firmware receiver's [category, action] packets.
enum Lumina {
    static func packet(forKey key: String, long: Bool) -> [UInt8]? {
        if key == "ok", long { return [1, 21] }
        switch key {
        case "up": return [1, 1]
        case "down": return [1, 2]
        case "left": return [1, 3]
        case "right": return [1, 4]
        case "ok": return [1, 5]
        case "back": return [1, 6]
        case "home": return [1, 7]
        case "menu": return [1, 8]
        case "settings": return [1, 9]
        case "recents", "apps": return [1, 10]
        case "volumeUp": return [2, 1]
        case "volumeDown": return [2, 2]
        case "mute": return [2, 3]
        case "power", "wakeup": return [3, 1]
        case "standby": return [3, 2]
        case "focusUp": return [4, 1]
        case "focusDown": return [4, 2]
        case "autoFocus": return [4, 3]
        case "input": return [4, 5]
        case "keystone": return [4, 16]
        case "next": return [7, 4]
        case "previous": return [7, 5]
        case "playPause": return [7, 6]
        default: return nil
        }
    }

    /// Keys the firmware receiver handles, for lighting up the remote UI.
    static let supported: Set<String> = [
        "up", "down", "left", "right", "ok", "back", "home", "menu", "settings", "recents", "apps",
        "volumeUp", "volumeDown", "mute", "power", "wakeup", "standby",
        "focusUp", "focusDown", "autoFocus", "input", "keystone",
        "next", "previous", "playPause", "pointer",
    ]
}
