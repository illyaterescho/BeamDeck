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

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?() } }
    }
    @Published private(set) var nearby: [NearbyProjector] = []
    @Published private(set) var bluetoothReady = false
    @Published private(set) var connectedName: String?

    var onStatus: (([String: Any]) -> Void)?
    var onReady: (() -> Void)?
    var onPhaseChange: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var session = Wire.Session()
    private var inbox = Data()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var wantsScan = false
    private var selected: UUID?
    private var attempt = UUID()
    private let serviceId = CBUUID(string: Wire.service)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var peripheralId: String? { peripheral?.identifier.uuidString }

    func scan() {
        wantsScan = true
        guard central.state == .poweredOn else { return }
        guard peripheral == nil, phase != .scanning else { return }
        phase = .scanning
        central.scanForPeripherals(withServices: [serviceId], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ id: UUID) {
        selected = id
        guard central.state == .poweredOn, peripheral?.identifier != id else { return }
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else { scan(); return }
        central.stopScan()
        resetConnection()
        peripheral = target
        target.delegate = self
        connectedName = target.name ?? nearby.first { $0.id == id }?.name
        phase = .connecting
        central.connect(target)
    }

    private func resetConnection() {
        let previous = peripheral
        peripheral = nil
        if let previous, central.state == .poweredOn { central.cancelPeripheralConnection(previous) }
        resetWire()
    }

    private func resetWire() {
        attempt = UUID()
        rx = nil
        inbox.removeAll()
        session = Wire.Session()
        failPending(.notConnected)
    }

    func disconnect() {
        selected = nil
        wantsScan = false
        if central.state == .poweredOn { central.stopScan() }
        resetConnection()
        connectedName = nil
        phase = .idle
    }

    func pair(pin: String) async throws {
        let current = attempt
        let reply = try await request("pair", ["pin": pin])
        guard current == attempt else { throw LinkError.notConnected }
        guard let token = reply["token"] as? String, let id = peripheralId else { throw LinkError.protocolMismatch }
        TokenStore.save(token, for: id)
        phase = .ready
        onReady?()
    }

    func request(_ op: String, _ params: [String: Any] = [:], timeout: Double = 6) async throws -> [String: Any] {
        guard let peripheral, let rx, session.key != nil else { throw LinkError.notConnected }
        nextId += 1
        let id = nextId
        var message = params
        message["id"] = id
        message["op"] = op
        let frame = try session.seal(message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(frame, to: peripheral, characteristic: rx)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: LinkError.timeout)
            }
        }
    }

    private func write(_ frame: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        // The receiver accepts regular writes, without the ATT long-write procedure.
        let chunk = min(peripheral.maximumWriteValueLength(for: .withoutResponse),
                        peripheral.maximumWriteValueLength(for: .withResponse))
        for part in Wire.fragments(frame, chunk: chunk) {
            peripheral.writeValue(part, for: characteristic, type: .withResponse)
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
                failConnection(LinkError.protocolMismatch.localizedDescription)
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
            if code == "unauthorized", phase == .ready {
                if let id = peripheralId { TokenStore.forget(id) }
                phase = .needsPin
            }
            continuation.resume(throwing: LinkError.remote(code))
        }
    }

    private func authenticate() {
        guard let id = peripheralId, let token = TokenStore.token(for: id) else {
            phase = .needsPin
            return
        }
        let current = attempt
        Task {
            do {
                _ = try await request("auth", ["token": token])
                guard current == attempt else { return }
                phase = .ready
                onReady?()
            } catch {
                guard current == attempt else { return }
                if error as? LinkError == .remote("unauthorized") {
                    TokenStore.forget(id)
                    phase = .needsPin
                } else {
                    failConnection(error.localizedDescription)
                }
            }
        }
    }

    private func failConnection(_ message: String) {
        resetConnection()
        phase = .failed(message)
        guard let selected else { return }
        let current = attempt
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard current == attempt, self.selected == selected else { return }
            connect(selected)
        }
    }
}

extension BeamLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothReady = central.state == .poweredOn
            guard bluetoothReady else {
                resetConnection()
                phase = central.state == .unauthorized ? .failed("Дозвольте BeamDeck доступ до Bluetooth у Налаштуваннях.")
                    : .failed(LinkError.bluetoothOff.localizedDescription)
                return
            }
            // Reconnect straight to the last projector, the way a hardware remote would.
            if let selected {
                connect(selected)
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
            if selected == peripheral.identifier, self.peripheral == nil { connect(peripheral.identifier) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            phase = .securing
            peripheral.discoverServices([serviceId])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            failConnection("Не вдалося під’єднатися. Перевірте, що приймач BeamDeck увімкнено.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            resetWire()
            // Stay attached: CoreBluetooth reconnects as soon as the projector is back in range.
            phase = .connecting
            central.connect(peripheral)
        }
    }
}

extension BeamLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
                failConnection(LinkError.protocolMismatch.localizedDescription)
                return
            }
            peripheral.discoverCharacteristics([CBUUID(string: Wire.rx), CBUUID(string: Wire.tx)], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            guard error == nil,
                  let rx = service.characteristics?.first(where: { $0.uuid == CBUUID(string: Wire.rx) && $0.properties.contains(.write) }),
                  let tx = service.characteristics?.first(where: { $0.uuid == CBUUID(string: Wire.tx) }) else {
                failConnection(LinkError.protocolMismatch.localizedDescription)
                return
            }
            self.rx = rx
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            guard error == nil, characteristic.isNotifying, let rx else {
                failConnection(LinkError.protocolMismatch.localizedDescription)
                return
            }
            write(session.hello, to: peripheral, characteristic: rx)
            let current = attempt
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard current == attempt, phase == .securing, session.key == nil else { return }
                failConnection(LinkError.timeout.localizedDescription)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral, error == nil,
                  let value = characteristic.value, let flags = value.first else { return }
            inbox.append(value.dropFirst())
            if inbox.count > 64 * 1024 { inbox.removeAll(); return }
            guard flags & 0x80 != 0 else { return }
            let frame = inbox
            inbox.removeAll()
            handle(frame: frame)
        }
    }
}
