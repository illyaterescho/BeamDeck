import CoreBluetooth
import Foundation

/// Direct link to the projector's built-in (firmware) receiver — the one Lumina Go drives.
/// Because that receiver is a system app, the firmware does not disable it, so navigation and
/// focus work where BeamDeck's own accessibility service gets switched off. See LUMINA_PROTOCOL.md.
@MainActor
final class LuminaLink: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, scanning, connecting, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            print("[BeamDeck] phase", String(describing: phase))
            onPhaseChange?()
        }
    }
    @Published private(set) var nearby: [NearbyProjector] = []
    @Published private(set) var connectedName: String?
    /// Diagnostics shown on the Projector tab.
    @Published private(set) var sentCount = 0
    @Published private(set) var ackedCount = 0
    @Published private(set) var lastError: String?

    var onPhaseChange: (() -> Void)?
    var onDiscovery: (() -> Void)?
    var onWriteError: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmd: CBCharacteristic?
    private var selected: UUID?
    private var outbound: [Data] = []
    private var writing = false
    private var motion = CGSize.zero
    private var wantsScan = false
    private let serviceId = CBUUID(string: "FFF0")
    private let cmdId = CBUUID(string: "FFF1")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var connected: Bool { phase == .ready }
    var peripheralId: String? { peripheral?.identifier.uuidString }

    func scan() {
        wantsScan = true
        guard central.state == .poweredOn, peripheral == nil, phase != .scanning else { return }
        phase = .scanning
        // Some firmwares advertise the name but not the service UUID, so scan broadly and filter by name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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

    func disconnect() {
        selected = nil
        wantsScan = false
        if central.state == .poweredOn { central.stopScan() }
        resetConnection()
        connectedName = nil
        phase = .idle
    }

    private func resetConnection() {
        let previous = peripheral
        peripheral = nil
        if let previous, central.state == .poweredOn { central.cancelPeripheralConnection(previous) }
        cmd = nil
        clearWrites()
    }

    private func clearWrites() {
        outbound.removeAll()
        writing = false
        motion = .zero
    }

    // MARK: sending

    func send(_ bytes: [UInt8], afterMotion: Bool = false) throws {
        var packets: [Data] = []
        if afterMotion {
            while let move = nextMotion() { packets.append(move) }
        }
        packets.append(Data(bytes))
        try enqueue(packets)
    }

    func send(_ command: Lumina.Command) throws {
        try enqueue(command.packets)
    }

    /// UTF-8 text, chunked with the 0xFF prefix and terminated by 0xFE, exactly as the receiver expects.
    func sendText(_ text: String, deepLink: Bool = false) throws {
        guard !text.isEmpty else { return }
        guard let peripheral, let cmd, connected else { throw LinkError.notConnected }
        let bytes = Array(text.utf8)
        let chunk = max(1, min(peripheral.maximumWriteValueLength(for: .withoutResponse),
                               peripheral.maximumWriteValueLength(for: writeType(cmd))) - 1)
        var packets = stride(from: 0, to: bytes.count, by: chunk).map { offset in
            let end = min(offset + chunk, bytes.count)
            return Data([deepLink ? 0xFD : 0xFF] + bytes[offset..<end])
        }
        packets.append(Data([0xFE]))
        try enqueue(packets)
    }

    func move(by delta: CGSize) {
        guard connected else { return }
        motion.width = min(254, max(-254, motion.width + delta.width))
        motion.height = min(254, max(-254, motion.height + delta.height))
        pumpWrites()
    }

    private func nextMotion() -> Data? {
        let dx = max(-127, min(127, Int(motion.width)))
        let dy = max(-127, min(127, Int(motion.height)))
        guard dx != 0 || dy != 0 else { return nil }
        motion.width -= CGFloat(dx)
        motion.height -= CGFloat(dy)
        return Data([7, 1, UInt8(bitPattern: Int8(dx)), UInt8(bitPattern: Int8(dy))])
    }

    private func enqueue(_ packets: [Data]) throws {
        guard connected else { throw LinkError.notConnected }
        guard outbound.count + packets.count <= 384 else { throw LinkError.remote("busy") }
        outbound.append(contentsOf: packets)
        pumpWrites()
    }

    /// Always write with response when the receiver allows it: verified on an HY350 MAX that it acts on
    /// acknowledged writes, and an acknowledgement also tells us the command really arrived.
    private func writeType(_ characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
    }

    private func pumpWrites() {
        guard connected, let peripheral, let cmd, !writing else { return }
        let type = writeType(cmd)
        while type == .withResponse || peripheral.canSendWriteWithoutResponse {
            guard let packet = outbound.isEmpty ? nextMotion() : outbound.removeFirst() else { return }
            writing = type == .withResponse
            peripheral.writeValue(packet, for: cmd, type: type)
            sentCount += 1
            print("[BeamDeck] write", packet.map { String(format: "%02x", $0) }.joined(separator: " "),
                  type == .withResponse ? "(ack)" : "(no ack)")
            if writing { return }
        }
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
            guard central.state == .poweredOn else {
                resetConnection()
                phase = .idle
                return
            }
            if let selected {
                connect(selected)
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
            if selected == peripheral.identifier, self.peripheral == nil { connect(peripheral.identifier) }
            onDiscovery?()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            peripheral.discoverServices([serviceId])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            let id = peripheral.identifier
            resetConnection()
            phase = .failed("Не вдалося під’єднатися до проєктора.")
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard selected == id, self.peripheral == nil else { return }
                connect(id)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            cmd = nil
            clearWrites()
            phase = .connecting
            central.connect(peripheral) // stay attached, like the stock remote
        }
    }
}

extension LuminaLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
                resetConnection()
                phase = .failed("Це не той приймач. Оновіть програму проєктора.")
                return
            }
            peripheral.discoverCharacteristics([cmdId], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            guard error == nil, let characteristic = service.characteristics?.first(where: {
                $0.uuid == cmdId && !$0.properties.intersection([.write, .writeWithoutResponse]).isEmpty
            }) else {
                resetConnection()
                phase = .failed("Bluetooth-приймач проєктора не приймає команди.")
                return
            }
            cmd = characteristic
            phase = .ready
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            pumpWrites()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral, characteristic.uuid == cmdId else { return }
            writing = false
            if let error {
                lastError = error.localizedDescription
                print("[BeamDeck] write failed:", error.localizedDescription)
                clearWrites()
                onWriteError?()
            } else {
                ackedCount += 1
                pumpWrites()
            }
        }
    }
}

/// Maps the remote's key names to the firmware receiver's [category, action] packets.
enum Lumina {
    struct Command: Identifiable {
        let title: String
        let category: UInt8
        let action: UInt8
        let metadata: String?

        init(_ title: String, _ category: UInt8, _ action: UInt8, metadata: String? = nil) {
            self.title = title
            self.category = category
            self.action = action
            self.metadata = metadata
        }

        var id: String { "\(category).\(action).\(metadata ?? "")" }
        var packets: [Data] {
            let command = Data([category, action])
            guard let metadata else { return [command] }
            return [Data([0xFC] + metadata.utf8), command]
        }

        static func value(_ title: String, _ action: UInt8, _ value: Int) -> Self {
            Self(title, 13, action, metadata: "value:\(value)")
        }

        static func toggles(_ action: UInt8) -> [Self] {
            [Self("Увімкнути", 12, action, metadata: "toggle:on"),
             Self("Вимкнути", 12, action, metadata: "toggle:off")]
        }
    }

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
        case "input": return [4, 5]
        case "cast": return [4, 30]
        case "next": return [7, 4]
        case "previous": return [7, 5]
        case "playPause": return [7, 6]
        default: return nil
        }
    }

    /// Keys this receiver handles. Autofocus (319), keystone (332) and the custom keys are vendor key codes
    /// that the HY350 MAX firmware ignores, so they are not offered.
    static let supported: Set<String> = [
        "up", "down", "left", "right", "ok", "back", "home", "menu", "settings", "recents", "apps",
        "volumeUp", "volumeDown", "mute", "power", "wakeup", "standby",
        "focusUp", "focusDown", "input", "cast", "next", "previous", "playPause", "pointer",
    ]

    static let shortcuts: [(id: String, label: String, packet: [UInt8])] = [
        ("lumina.youtube", "YouTube", [4, 22]),
        ("lumina.netflix", "Netflix", [4, 21]),
        ("lumina.disney", "Disney+", [4, 23]),
        ("lumina.prime", "Prime Video", [4, 31]),
        ("lumina.browser", "Браузер", [8, 3]),
        ("lumina.files", "Файли", [8, 4]),
        ("lumina.music", "Музика", [8, 1]),
        ("lumina.video", "Відео", [8, 2]),
        ("lumina.gallery", "Галерея", [8, 5]),
        ("lumina.camera", "Камера", [8, 6]),
        ("lumina.usb", "USB", [4, 32]),
        ("lumina.store", "Магазин програм", [11, 20]),
    ]

    static let imageMenus: [Command] = [
        Command("Джерело сигналу", 4, 5), Command("Яскравість", 10, 1),
        Command("Контраст", 10, 2), Command("Трапеція", 11, 12),
        Command("Підгонка зображення", 10, 4), Command("Налаштування дисплея", 11, 19),
        Command("Збільшити масштаб", 4, 8), Command("Зменшити масштаб", 4, 9),
    ]

    static let settingsMenus: [Command] = [
        Command("Загальні налаштування", 11, 21), Command("Wi-Fi", 9, 1),
        Command("Bluetooth", 9, 2), Command("Звук", 9, 4), Command("Аудіорежим", 11, 11),
        Command("Мова", 9, 5), Command("Дата й час", 9, 6), Command("Програми", 9, 7),
        Command("Сховище", 9, 8), Command("Мережа", 9, 9), Command("Про пристрій", 9, 11),
        Command("Спеціальні можливості", 9, 12), Command("Клавіатура", 11, 1),
        Command("Живлення", 11, 10), Command("IP-адреса Wi-Fi", 11, 18),
    ]

    static let castingMenus: [Command] = [
        Command("AirPlay", 4, 17), Command("Miracast", 4, 18), Command("Дублювання екрана", 11, 8),
        Command("Трансляція", 4, 30), Command("Bluetooth-колонка", 4, 15),
    ]

    static let mediaCommands: [Command] = [
        Command("Відтворити", 7, 1), Command("Пауза", 7, 2), Command("Зупинити", 7, 3),
        Command("Перемотати назад", 7, 7), Command("Перемотати вперед", 7, 8),
    ]

    static let keyboardCommands: [Command] = [
        Command("Пробіл", 6, 3), Command("Tab", 6, 4), Command("Esc", 6, 5),
    ]
}
