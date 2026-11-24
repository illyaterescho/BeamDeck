import CoreBluetooth
import Foundation

struct NearbyProjector: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// CoreBluetooth central for the BeamDeck receiver. All callbacks arrive on the main queue.
@MainActor
final class BeamLink: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, scanning, connecting, securing, needsPin, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nearby: [NearbyProjector] = []
    @Published private(set) var bluetoothReady = false
    @Published private(set) var connectedName: String?

    var onStatus: (([String: Any]) -> Void)?
    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var session = Wire.Session()
    private var inbox = Data()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var wantsScan = false
    private let serviceId = CBUUID(string: Wire.service)
    private let lastKey = "lastProjector"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var peripheralId: String? { peripheral?.identifier.uuidString }

    func scan() {
        wantsScan = true
        guard central.state == .poweredOn else { return }
        nearby.removeAll()
        if case .ready = phase { return }
        phase = .scanning
        central.scanForPeripherals(withServices: [serviceId], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ id: UUID) {
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        disconnect(keepPhase: true)
        peripheral = target
        target.delegate = self
        connectedName = target.name ?? nearby.first { $0.id == id }?.name
        phase = .connecting
        central.connect(target)
    }

    func disconnect(keepPhase: Bool = false) {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        rx = nil
        failPending(.notConnected)
        if !keepPhase { phase = .idle }
    }

    func forgetCurrent() {
        if let id = peripheralId { TokenStore.forget(id) }
        UserDefaults.standard.removeObject(forKey: lastKey)
        disconnect()
        scan()
    }

    func pair(pin: String) async throws {
        let reply = try await request("pair", ["pin": pin])
        guard let token = reply["token"] as? String, let id = peripheralId else { throw LinkError.protocolMismatch }
        TokenStore.save(token, for: id)
        UserDefaults.standard.set(id, forKey: lastKey)
        phase = .ready
        onReady?()
    }

    var token: String? { peripheralId.flatMap(TokenStore.token(for:)) }

    func request(_ op: String, _ params: [String: Any] = [:], timeout: Double = 6) async throws -> [String: Any] {
        guard let peripheral, let rx, session.key != nil else { throw LinkError.notConnected }
        nextId += 1
        let id = nextId
        var message = params
        message["id"] = id
        message["op"] = op
        let frame = try session.seal(message)
        let chunk = peripheral.maximumWriteValueLength(for: .withoutResponse)
        for part in Wire.fragments(frame, chunk: chunk) {
            peripheral.writeValue(part, for: rx, type: .withResponse)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: LinkError.timeout)
            }
        }
    }

    private func failPending(_ error: LinkError) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    private func handle(frame: Data) {
        if frame.first == 0x02 {
            do {
                try session.accept(serverHello: frame)
            } catch {
                phase = .failed(LinkError.protocolMismatch.localizedDescription)
                return
            }
            authenticate()
            return
        }
        guard let message = try? session.open(frame) else { return }
        if message["op"] as? String == "status", let status = message["status"] as? [String: Any] {
            onStatus?(status)
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if message["ok"] as? Bool == true {
            continuation.resume(returning: message)
        } else {
            let code = message["error"] as? String ?? "internal_error"
            if code == "unauthorized" { phase = .needsPin }
            continuation.resume(throwing: LinkError.remote(code))
        }
    }

    private func authenticate() {
        guard let id = peripheralId, let token = TokenStore.token(for: id) else {
            phase = .needsPin
            return
        }
        Task {
            do {
                _ = try await request("auth", ["token": token])
                UserDefaults.standard.set(id, forKey: lastKey)
                phase = .ready
                onReady?()
            } catch {
                TokenStore.forget(id)
                phase = .needsPin
            }
        }
    }
}

extension BeamLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothReady = central.state == .poweredOn
            guard bluetoothReady else {
                phase = central.state == .unauthorized ? .failed("Дозвольте BeamDeck доступ до Bluetooth у Налаштуваннях.")
                    : .failed(LinkError.bluetoothOff.localizedDescription)
                return
            }
            // Reconnect straight to the last projector, the way a hardware remote would.
            if let last = UserDefaults.standard.string(forKey: lastKey), let id = UUID(uuidString: last) {
                connect(id)
            } else if wantsScan || phase == .idle {
                scan()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Проєктор"
            if let index = nearby.firstIndex(where: { $0.id == peripheral.identifier }) {
                nearby[index].rssi = RSSI.intValue
                nearby[index].name = name
            } else {
                nearby.append(NearbyProjector(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            phase = .securing
            peripheral.discoverServices([serviceId])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            phase = .failed("Не вдалося під’єднатися. Перевірте, що приймач BeamDeck увімкнено.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            failPending(.notConnected)
            guard peripheral == self.peripheral else { return }
            rx = nil
            session = Wire.Session()
            // Stay attached: CoreBluetooth reconnects as soon as the projector is back in range.
            phase = .connecting
            central.connect(peripheral)
        }
    }
}

extension BeamLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
                phase = .failed(LinkError.protocolMismatch.localizedDescription)
                return
            }
            peripheral.discoverCharacteristics([CBUUID(string: Wire.rx), CBUUID(string: Wire.tx)], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == CBUUID(string: Wire.rx) { rx = characteristic }
                if characteristic.uuid == CBUUID(string: Wire.tx) { peripheral.setNotifyValue(true, for: characteristic) }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.isNotifying, let rx else { return }
            session = Wire.Session()
            inbox.removeAll()
            let chunk = peripheral.maximumWriteValueLength(for: .withoutResponse)
            for part in Wire.fragments(session.hello, chunk: chunk) {
                peripheral.writeValue(part, for: rx, type: .withResponse)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let value = characteristic.value, let flags = value.first else { return }
            inbox.append(value.dropFirst())
            if inbox.count > 64 * 1024 { inbox.removeAll(); return }
            guard flags & 0x80 != 0 else { return }
            let frame = inbox
            inbox.removeAll()
            handle(frame: frame)
        }
    }
}
