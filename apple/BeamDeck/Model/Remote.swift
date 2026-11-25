import Foundation
import SwiftUI

/// Snapshot of the receiver, decoded loosely so older receivers still render.
struct ProjectorStatus {
    var raw: [String: Any] = [:]

    private func object(_ key: String) -> [String: Any] { raw[key] as? [String: Any] ?? [:] }

    var model: String { object("device")["model"] as? String ?? "Проєктор" }
    var android: String { object("device")["android"] as? String ?? "" }
    var volumeLevel: Int { object("volume")["current"] as? Int ?? 0 }
    var volumeMin: Int { object("volume")["min"] as? Int ?? 0 }
    var volumeMax: Int { max(volumeMin + 1, object("volume")["max"] as? Int ?? 15) }
    var hasVolume: Bool { object("volume")["current"] is Int && object("volume")["max"] is Int }
    var volumePercent: Int {
        min(100, max(0, Int((100 * Double(volumeLevel - volumeMin) / Double(volumeMax - volumeMin)).rounded())))
    }
    var muted: Bool { object("volume")["muted"] as? Bool ?? false }
    var playing: Bool { object("media")["playing"] as? Bool ?? false }
    var nowPlayingApp: String? { object("media")["app"] as? String }
    var receiver: [String: Any] { object("receiver") }
    var adb: String { receiver["adb"] as? String ?? "off" }
    var accessibility: Bool { receiver["accessibility"] as? Bool ?? false }
    var lan: String? { receiver["lan"] as? String }
    var keyboard: String { object("projector")["keyboard"] as? String ?? "keyboard_required" }
    var sleepRemaining: Double? { (object("sleep")["remainingMs"] as? Double).map { $0 / 1000 } }
    var learning: [String: Any]? { raw["learning"] as? [String: Any] }

    /// nil = available, otherwise a reason code.
    func reason(_ key: String) -> String? {
        guard let capability = object("capabilities")[key] as? [String: Any] else { return raw.isEmpty ? nil : "unsupported" }
        return capability["available"] as? Bool == true ? nil : capability["reason"] as? String ?? "unsupported"
    }

    func available(_ key: String) -> Bool { reason(key) == nil }
}

struct LaunchableApp: Identifiable, Hashable {
    let id: String
    let label: String
}

@MainActor
final class Remote: ObservableObject {
    let link = BeamLink()
    let lumina = LuminaLink()
    @Published private(set) var status = ProjectorStatus()
    @Published private(set) var wifiReady = false
    @Published private(set) var wifiAddress: String?
    @Published var notice: String?
    @Published private(set) var apps: [LaunchableApp] = []
    @Published var haptic = 0
    @Published private var volumeTarget: Int?
    @Published private var firmwareVolume: Int?

    private enum Projector: Equatable {
        case beam(UUID), wifi(String), firmware(UUID)
    }

    private enum TouchInput {
        case move(CGSize), click, scroll(Double)

        var command: (String, [String: Any]) {
            switch self {
            case .move(let delta): ("pointer", ["dx": Double(delta.width), "dy": Double(delta.height)])
            case .click: ("click", [:])
            case .scroll(let amount): ("scroll", ["dx": 0, "dy": amount])
            }
        }
    }

    private enum VolumeInput {
        case level(Int), key(String)
    }

    private var projector: Projector?
    private var receiverStatus = ProjectorStatus()
    private var generation = UUID()
    private var wifiProbe: UUID?
    private var wifiNeedsPin = false
    private(set) var sessionToken: String?
    private var touchQueue: [TouchInput] = []
    private var touchTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var volumeQueue: [VolumeInput] = []
    private let pointerStream = PointerStream()
    private var streamRetryAt = ContinuousClock.now
    private var nextLegacyMove = ContinuousClock.now
    private var noticeTask: Task<Void, Never>?
    #if os(iOS)
    private var storedPhoneMirror: AnyObject?

    @available(iOS 27.0, *)
    var phoneMirror: PhoneMirror {
        if let mirror = storedPhoneMirror as? PhoneMirror { return mirror }
        let mirror = PhoneMirror()
        storedPhoneMirror = mirror
        return mirror
    }
    #endif

    let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    init() {
        if demo { status = ProjectorStatus(raw: Self.sample); return }
        link.onStatus = { [weak self] in self?.receiveStatus($0) }
        link.onReady = { [weak self] in self?.beamReady() }
        link.onPhaseChange = { [weak self] in self?.updateStatus() }
        lumina.onPhaseChange = { [weak self] in self?.firmwareChanged() }
        lumina.onDiscovery = { [weak self] in self?.findMatchingFirmware() }
        lumina.onWriteError = { [weak self] in self?.show("Bluetooth-приймач відхилив команду.") }

        let saved = UserDefaults.standard
        if let address = saved.string(forKey: "lastWiFiProjector"), let valid = WiFi.receiverAddress(address) {
            select(.wifi(valid))
        } else if let id = saved.string(forKey: "lastProjector").flatMap(UUID.init(uuidString:)) {
            select(.beam(id))
        } else if let id = saved.string(forKey: "lastLumina").flatMap(UUID.init(uuidString:)) {
            select(.firmware(id))
        }
    }

    var firmware: Bool { lumina.connected }
    var receiverReady: Bool { wifiReady || link.phase == .ready }
    var projectOverWiFi: ProjectorConnection? {
        guard wifiReady, let address = wifiAddress, let token = sessionToken else { return nil }
        return ProjectorConnection(address: address, token: token)
    }
    var canSetVolume: Bool { demo || hasAgentVolume || firmware }
    var volumeIsEstimated: Bool { firmware && !hasAgentVolume }
    var volumePercent: Int? {
        if let volumeTarget { return volumeTarget }
        if demo || hasAgentVolume { return demo ? status.volumePercent : receiverStatus.volumePercent }
        return firmware ? firmwareVolume : nil
    }
    var hasReceiverSession: Bool { sessionToken != nil && !wifiNeedsPin || link.phase == .ready }
    var showRemote: Bool {
        if demo || wifiReady { return true }
        if link.phase == .needsPin { return false }
        return firmware || hasReceiverSession
    }

    var connectionLabel: String {
        if demo { return "Демо" }
        if wifiReady { return link.phase == .ready || firmware ? "Wi-Fi + Bluetooth" : "Wi-Fi" }
        if receiverReady || firmware { return "Bluetooth" }
        if link.phase == .connecting || link.phase == .securing || lumina.phase == .connecting {
            return "Повторне підключення…"
        }
        return "Від’єднано"
    }

    var attachedFirmware: UUID? {
        guard let id = receiverID else { return nil }
        return UserDefaults.standard.string(forKey: "firmwareFor:\(id)").flatMap(UUID.init(uuidString:))
    }

    private var receiverID: String? {
        switch projector {
        case .beam(let id): id.uuidString
        case .wifi(let address): "wifi:\(address)"
        default: nil
        }
    }

    private var hasAgentVolume: Bool {
        receiverReady && receiverStatus.hasVolume && receiverStatus.available("volume")
    }

    func connectBeam(_ id: UUID) {
        if projector == .beam(id) { link.connect(id) }
        else { select(.beam(id)) }
    }

    func connectFirmware(_ id: UUID) {
        if projector == .firmware(id) { lumina.connect(id) }
        else { select(.firmware(id)) }
    }

    func attachFirmware(_ id: UUID) {
        guard let receiverID else { return }
        UserDefaults.standard.set(id.uuidString, forKey: "firmwareFor:\(receiverID)")
        lumina.connect(id)
    }

    func detachFirmware() {
        guard let receiverID else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "firmwareFor:\(receiverID)")
        defaults.set(true, forKey: "firmwareDisabled:\(receiverID)")
        lumina.disconnect()
        lumina.scan()
    }

    func disconnect() { select(nil) }

    func forgetProjector() {
        if let receiverID {
            TokenStore.forget(receiverID)
            for prefix in ["receiverAddress:", "firmwareFor:", "firmwareDisabled:"] {
                UserDefaults.standard.removeObject(forKey: prefix + receiverID)
            }
        }
        select(nil)
    }

    func pairWiFi(address: String, pin: String) async throws {
        guard let address = WiFi.receiverAddress(address) else {
            throw LinkError.remote("invalid_lan")
        }
        let current = generation
        let token = try await WiFi.pair(address, pin: pin)
        let snapshot = try await WiFi.status(address, token: token)
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        TokenStore.save(token, for: "wifi:\(address)")
        select(.wifi(address))
        wifiReady = true
        receiveStatus(snapshot)
        saveSelection()
    }

    private func select(_ next: Projector?) {
        #if os(iOS)
        if #available(iOS 27.0, *) { (storedPhoneMirror as? PhoneMirror)?.stop() }
        #endif
        generation = UUID()
        projector = next
        link.disconnect()
        lumina.disconnect()
        touchTask?.cancel()
        touchTask = nil
        touchQueue.removeAll()
        volumeTask?.cancel()
        volumeTask = nil
        volumeQueue.removeAll()
        volumeTarget = nil
        firmwareVolume = nil
        pointerStream.close()
        wifiProbe = nil
        wifiReady = false
        wifiNeedsPin = false
        receiverStatus = ProjectorStatus()
        apps = []
        streamRetryAt = .now
        nextLegacyMove = .now

        let saved = UserDefaults.standard
        sessionToken = receiverID.flatMap(TokenStore.token(for:))
        switch next {
        case .beam(let id):
            wifiAddress = saved.string(forKey: "receiverAddress:\(id.uuidString)").flatMap(WiFi.receiverAddress)
            link.connect(id)
            if let attachedFirmware { lumina.connect(attachedFirmware) }
            else { lumina.scan() }
            findMatchingFirmware()
        case .wifi(let address):
            wifiAddress = address
            if let attachedFirmware { lumina.connect(attachedFirmware) }
            else { lumina.scan() }
        case .firmware(let id):
            wifiAddress = nil
            lumina.connect(id)
        case nil:
            wifiAddress = nil
            saveSelection()
            link.scan()
            lumina.scan()
        }
        updateStatus()
        if wifiAddress != nil { Task { await refreshWiFi() } }
    }

    private func saveSelection() {
        let saved = UserDefaults.standard
        saved.removeObject(forKey: "lastProjector")
        saved.removeObject(forKey: "lastWiFiProjector")
        saved.removeObject(forKey: "lastLumina")
        switch projector {
        case .beam(let id): saved.set(id.uuidString, forKey: "lastProjector")
        case .wifi(let address): saved.set(address, forKey: "lastWiFiProjector")
        case .firmware(let id): saved.set(id.uuidString, forKey: "lastLumina")
        case nil: break
        }
    }

    private func findMatchingFirmware() {
        guard case .beam(let id) = projector, let receiverID,
              attachedFirmware == nil, !UserDefaults.standard.bool(forKey: "firmwareDisabled:\(receiverID)"),
              lumina.nearby.contains(where: { $0.id == id }) else { return }
        attachFirmware(id)
    }

    private func firmwareChanged() {
        if case .firmware = projector, firmware { saveSelection() }
        if !firmware { firmwareVolume = nil }
        updateStatus()
    }

    private func beamReady() {
        guard case .beam(let id) = projector, link.peripheralId == id.uuidString else { return }
        sessionToken = TokenStore.token(for: id.uuidString)
        wifiNeedsPin = false
        saveSelection()
        findMatchingFirmware()
        let current = generation
        Task {
            if let snapshot = try? await link.request("status"), current == generation, !wifiReady {
                receiveStatus(snapshot)
            }
            await refreshWiFi()
        }
    }

    private func receiveStatus(_ raw: [String: Any]) {
        guard receiverID != nil else { return }
        let snapshot = ProjectorStatus(raw: raw)
        if case .beam(let id) = projector, let address = snapshot.lan.flatMap(WiFi.receiverAddress),
           address != wifiAddress {
            wifiAddress = address
            wifiReady = false
            wifiNeedsPin = false
            wifiProbe = nil
            pointerStream.close()
            streamRetryAt = .now
            UserDefaults.standard.set(address, forKey: "receiverAddress:\(id.uuidString)")
            Task { await refreshWiFi() }
        }
        receiverStatus = snapshot
        updateStatus()
    }

    private func updateStatus() {
        var raw = receiverStatus.raw
        if firmware {
            if raw.isEmpty || !receiverReady {
                raw = Self.luminaStatus
            } else {
                var capabilities = raw["capabilities"] as? [String: Any] ?? [:]
                for key in Lumina.supported.union(["volume"]) { capabilities[key] = ["available": true] }
                raw["capabilities"] = capabilities
                var projector = raw["projector"] as? [String: Any] ?? [:]
                projector["keyboard"] = "ready"
                raw["projector"] = projector
            }
        }
        status = ProjectorStatus(raw: raw)
    }

    func monitorWiFi() async {
        guard !demo else { return }
        while !Task.isCancelled {
            await refreshWiFi()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refreshWiFi() async {
        guard let address = wifiAddress, let token = sessionToken, wifiProbe == nil, !wifiNeedsPin else { return }
        let current = generation
        let probe = UUID()
        wifiProbe = probe
        defer { if wifiProbe == probe { wifiProbe = nil } }
        do {
            let snapshot = try await WiFi.status(address, token: token)
            guard current == generation, wifiProbe == probe, sessionToken == token, !Task.isCancelled else { return }
            wifiReady = true
            receiveStatus(snapshot)
        } catch {
            guard current == generation, wifiProbe == probe, sessionToken == token, !Task.isCancelled else { return }
            loseWiFi(error)
        }
    }

    private func loseWiFi(_ error: Error) {
        wifiReady = false
        pointerStream.close()
        if error as? LinkError == .remote("unauthorized") { wifiNeedsPin = true }
        updateStatus()
    }

    func send(_ op: String, _ params: [String: Any] = [:]) {
        haptic += 1
        if op == "click" { touch(.click); return }
        let current = generation
        Task {
            guard current == generation else { return }
            do {
                if try sendViaFirmwareIfPreferred(op, params) { return }
                let reply = try await call(op, params)
                guard current == generation else { return }
                if let volume = reply["volume"] as? [String: Any] {
                    receiverStatus.raw["volume"] = volume
                    updateStatus()
                }
            } catch {
                guard current == generation else { return }
                do {
                    if case .remote(let code) = error as? LinkError,
                       Self.firmwareFallbackReasons.contains(code), try sendViaFirmware(op, params) { return }
                    if !receiverReady, WiFi.commandNotDelivered(error), try sendViaFirmwareIfPreferred(op, params) { return }
                    show(error.localizedDescription)
                } catch { show(error.localizedDescription) }
            }
        }
    }

    func key(_ name: String, long: Bool = false) {
        if name == "volumeUp" || name == "volumeDown" || name == "mute" {
            haptic += 1
            if demo {
                if name == "mute" {
                    var volume = status.raw["volume"] as? [String: Any] ?? [:]
                    volume["muted"] = !status.muted
                    status.raw["volume"] = volume
                } else {
                    setVolume(percent: status.volumePercent + (name == "volumeUp" ? 7 : -7))
                }
                return
            }
            enqueueVolume(.key(name))
            return
        }
        send("key", ["key": name, "long": long])
    }

    func setVolume(percent: Int) {
        guard canSetVolume else { return }
        let percent = max(0, min(100, percent))
        if volumeTarget == percent { return }
        if demo {
            status.raw["volume"] = ["current": percent, "min": 0, "max": 100, "muted": false]
            return
        }
        if enqueueVolume(.level(percent)) { volumeTarget = percent }
    }

    @discardableResult
    private func enqueueVolume(_ input: VolumeInput) -> Bool {
        if case .level = input, case .level? = volumeQueue.last {
            volumeQueue[volumeQueue.count - 1] = input
        } else {
            guard volumeQueue.count < 16 else { return false }
            volumeQueue.append(input)
        }
        if volumeTask == nil {
            let current = generation
            volumeTask = Task { await flushVolume(for: current) }
        }
        return true
    }

    private func flushVolume(for current: UUID) async {
        defer {
            if current == generation {
                volumeTask = nil
                volumeTarget = nil
            }
        }
        while !volumeQueue.isEmpty, current == generation, !Task.isCancelled {
            do {
                let reply: [String: Any]
                switch volumeQueue.removeFirst() {
                case .level(let percent):
                    if firmware && !hasAgentVolume {
                        try lumina.send(.value("Гучність", 2, percent))
                        firmwareVolume = percent
                        continue
                    }
                    let min = receiverStatus.volumeMin
                    let span = receiverStatus.volumeMax - min
                    let level = min + (span * percent + 50) / 100
                    reply = try await call("volume", ["level": level])
                case .key(let name):
                    let params = ["key": name]
                    if try sendViaFirmwareIfPreferred("key", params) {
                        if name != "mute" { firmwareVolume = nil }
                        continue
                    }
                    reply = try await call("key", params)
                }
                guard current == generation, !Task.isCancelled else { return }
                if let volume = reply["volume"] as? [String: Any] {
                    receiverStatus.raw["volume"] = volume
                    updateStatus()
                }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                show(error.localizedDescription)
            }
        }
    }

    func firmwareCommand(_ command: Lumina.Command) {
        haptic += 1
        do { try lumina.send(command) }
        catch { show(error.localizedDescription) }
    }

    func firmwareRightClick() {
        haptic += 1
        do { try lumina.send([7, 3], afterMotion: true) }
        catch { show(error.localizedDescription) }
    }

    func firmwareHorizontalScroll(_ amount: Double) {
        let step = max(-127, min(127, Int(amount / 18)))
        guard step != 0 else { return }
        do { try lumina.send([7, 7, UInt8(bitPattern: Int8(step))]) }
        catch { show(error.localizedDescription) }
    }

    private func sendViaFirmwareIfPreferred(_ op: String, _ params: [String: Any]) throws -> Bool {
        guard firmware else { return false }
        if op == "key", receiverReady, let key = params["key"] as? String, receiverStatus.available(key) { return false }
        if op == "open", receiverReady, (params["destination"] as? String) != "url" { return false }
        return try sendViaFirmware(op, params)
    }

    private func sendViaFirmware(_ op: String, _ params: [String: Any]) throws -> Bool {
        guard firmware else { return false }
        switch op {
        case "key":
            guard let key = params["key"] as? String,
                  let packet = Lumina.packet(forKey: key, long: params["long"] as? Bool == true) else { return false }
            try lumina.send(packet)
        case "text":
            switch params["action"] as? String {
            case "text":
                guard let text = params["text"] as? String else { return false }
                try lumina.sendText(text)
            case "delete": try lumina.send([6, 1])
            case "enter": try lumina.send([6, 2])
            default: return false
            }
        case "open":
            switch params["destination"] as? String {
            case "url":
                guard let value = params["value"] as? String,
                      let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
                      url.host != nil else { throw LinkError.remote("invalid_url") }
                try lumina.sendText(value, deepLink: true)
            case "settings": try lumina.send([1, 9])
            default: return false
            }
        case "launch":
            guard let shortcut = Lumina.shortcuts.first(where: { $0.id == params["appId"] as? String }) else { return false }
            try lumina.send(shortcut.packet)
        default: return false
        }
        return true
    }

    @discardableResult
    func call(_ op: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        if demo { return op == "apps" ? ["apps": Self.sampleApps] : [:] }
        if wifiReady, let address = wifiAddress, let token = sessionToken {
            let current = generation
            do {
                return try await WiFi.rpc(address, token: token, op: op, params: params)
            } catch {
                guard current == generation, address == wifiAddress, token == sessionToken else { throw CancellationError() }
                if WiFi.connectionFailed(error) { loseWiFi(error) }
                // An acknowledgement can be lost after the projector has already acted.
                guard WiFi.commandNotDelivered(error), link.phase == .ready else { throw error }
            }
        }
        if link.phase == .ready { return try await link.request(op, params) }
        throw LinkError.notConnected
    }

    func loadApps() async {
        let current = generation
        let shortcuts = Lumina.shortcuts.map { LaunchableApp(id: $0.id, label: $0.label) }
        if firmware, !receiverReady { apps = shortcuts; return }
        let reply = try? await call("apps")
        guard current == generation else { return }
        let installed = (reply?["apps"] as? [[String: Any]])?.compactMap { entry -> LaunchableApp? in
            guard let id = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
            return LaunchableApp(id: id, label: label)
        } ?? []
        guard firmware else { apps = installed; return }
        if receiverStatus.available("launch") {
            let labels = Set(installed.map { $0.label.lowercased() })
            apps = installed + shortcuts.filter { !labels.contains($0.label.lowercased()) }
        } else {
            let labels = Set(shortcuts.map { $0.label.lowercased() })
            apps = shortcuts + installed.filter { !labels.contains($0.label.lowercased()) }
        }
    }

    func move(by delta: CGSize) { touch(.move(delta)) }
    func scroll(by amount: Double) { touch(.scroll(amount)) }

    private func touch(_ input: TouchInput) {
        guard !demo else { return }
        if firmware {
            do {
                switch input {
                case .move(let delta): lumina.move(by: delta)
                case .click: try lumina.send([7, 2], afterMotion: true)
                case .scroll(let amount):
                    let step = max(-127, min(127, Int(amount / 18)))
                    if step != 0 { try lumina.send([7, 4, UInt8(bitPattern: Int8(step))]) }
                }
            } catch { show(error.localizedDescription) }
            return
        }
        guard receiverReady else { return }
        guard status.available("pointer") else {
            if case .click = input { show(Reason.text(status.reason("pointer") ?? "unsupported")) }
            return
        }
        switch (touchQueue.last, input) {
        case (.move(let previous)?, .move(let delta)):
            touchQueue[touchQueue.count - 1] = .move(CGSize(
                width: min(512, max(-512, previous.width + delta.width)),
                height: min(512, max(-512, previous.height + delta.height))
            ))
        case (.scroll(let previous)?, .scroll(let amount)):
            touchQueue[touchQueue.count - 1] = .scroll(min(720, max(-720, previous + amount)))
        default:
            if touchQueue.count < 8 { touchQueue.append(input) }
        }
        guard touchTask == nil else { return }
        let current = generation
        touchTask = Task { await flushTouch(for: current) }
    }

    private func flushTouch(for current: UUID) async {
        defer { if current == generation { touchTask = nil } }
        while !Task.isCancelled, !touchQueue.isEmpty, current == generation {
            let streaming = wifiReady && receiverStatus.receiver["pointerStream"] as? Bool == true && .now >= streamRetryAt
            let viaBLE = !streaming && link.phase == .ready
            if !streaming, !viaBLE, wifiReady {
                try? await Task.sleep(until: nextLegacyMove, clock: .continuous)
            }
            guard !Task.isCancelled, current == generation, !touchQueue.isEmpty else { return }
            let input = touchQueue.removeFirst()
            if firmware { touch(input); continue }
            let (op, params) = input.command
            do {
                if streaming, let address = wifiAddress, let token = sessionToken {
                    try await pointerStream.send(address: address, token: token, op: op, params: params)
                    try? await Task.sleep(for: .milliseconds(12))
                } else if viaBLE, link.phase == .ready {
                    _ = try await link.request(op, params, timeout: 1.2)
                } else if wifiReady, let address = wifiAddress, let token = sessionToken {
                    nextLegacyMove = .now.advanced(by: .milliseconds(210))
                    _ = try await WiFi.rpc(address, token: token, op: op, params: params, timeout: 0.8)
                }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                if streaming, !(error is LinkError) {
                    streamRetryAt = .now.advanced(by: .seconds(3))
                }
                if !streaming, !viaBLE, wifiReady, WiFi.connectionFailed(error) { loseWiFi(error) }
                if case .click = input { show(error.localizedDescription) }
            }
        }
    }

    private static let firmwareFallbackReasons: Set<String> = [
        "unsupported", "no_focus", "accessibility_required", "adb_required", "adb_authorizing",
        "learn_required", "keyboard_required", "media_access_required", "no_media", "media_action_unavailable",
    ]

    private static let sampleApps: [[String: Any]] = ["YouTube", "Netflix", "VLC", "Kodi", "Браузер", "Файли", "Prime Video", "Spotify"]
        .enumerated().map { ["id": "demo.app\($0.offset)/.Main", "label": $0.element] }

    private static let sample: [String: Any] = [
        "device": ["model": "HY350 MAX", "android": "11"],
        "volume": ["current": 9, "min": 0, "max": 15, "muted": false],
        "media": ["playing": true, "app": "YouTube"],
        "receiver": ["adb": "ready", "accessibility": true, "lan": "http://192.168.0.24:8765"],
        "projector": ["keyboard": "ready"],
        "capabilities": Dictionary(uniqueKeysWithValues: ["up", "down", "left", "right", "ok", "back", "home", "menu", "volume",
            "volumeUp", "volumeDown", "mute", "playPause", "next", "previous", "focusUp", "focusDown", "pointer", "screen",
            "standby", "wakeup", "power"].map { ($0, ["available": true]) })
            .merging(["autoFocus": ["available": false, "reason": "learn_required"]]) { $1 },
        "learning": NSNull(),
    ]

    /// Capabilities exposed by the firmware receiver without an Agent status feed.
    private static let luminaStatus: [String: Any] = [
        "device": ["model": "Проєктор", "android": ""],
        "volume": ["current": 0, "min": 0, "max": 100, "muted": false],
        "media": ["playing": NSNull(), "app": NSNull()],
        "receiver": ["adb": "off", "accessibility": false],
        "projector": ["keyboard": "ready"],
        "capabilities": Dictionary(uniqueKeysWithValues: Lumina.supported.union(["volume"]).map { ($0, ["available": true]) })
            .merging([
                "sleep": ["available": false, "reason": "unsupported"],
                "launch": ["available": false, "reason": "unsupported"],
                "screen": ["available": false, "reason": "unsupported"],
            ]) { $1 },
        "learning": NSNull(),
    ]

    func show(_ text: String) {
        noticeTask?.cancel()
        withAnimation(.snappy) { notice = text }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { notice = nil }
        }
    }
}

struct ProjectorConnection: Hashable, Sendable {
    let address: String
    let token: String
}

// All receiver URLs originate from pairing or the authenticated BLE status response.
enum WiFi {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ReceiverSessionDelegate(), delegateQueue: nil)
    }()

    static func receiverAddress(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value.contains("://") ? value : "http://\(value)"),
              parts.scheme == "http", parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/", parts.port == nil || parts.port == 8765,
              let host = parts.host else { return nil }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt8($0) }
        guard components.count == 4, octets.count == 4, host == octets.map(String.init).joined(separator: ".") else { return nil }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254): return "http://\(host):8765"
        default: return nil
        }
    }

    private static func request(_ address: String, path: String, token: String?, timeout: Double) throws -> URLRequest {
        guard let canonical = receiverAddress(address), let base = URL(string: canonical) else { throw LinkError.notConnected }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        if let token { request.setValue("BeamDeckSession=\(token)", forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        return request
    }

    private static func post(_ request: inout URLRequest, body: [String: Any]) throws {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-BeamDeck-Request")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    private static func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LinkError.protocolMismatch }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            throw LinkError.remote(code ?? (response.statusCode == 401 ? "unauthorized" : "unsupported"))
        }
        return (data, response)
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LinkError.protocolMismatch
        }
        return object
    }

    static func pair(_ address: String, pin: String) async throws -> String {
        var request = try request(address, path: "api/v1/pair", token: nil, timeout: 3)
        try post(&request, body: ["pin": pin])
        let (data, response) = try await response(request)
        guard try json(data)["paired"] as? Bool == true, let url = response.url,
              let header = response.value(forHTTPHeaderField: "Set-Cookie"),
              let token = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
                .first(where: { $0.name == "BeamDeckSession" })?.value else { throw LinkError.protocolMismatch }
        return token
    }

    static func status(_ address: String, token: String) async throws -> [String: Any] {
        let request = try request(address, path: "api/v1/status", token: token, timeout: 1.5)
        let (data, _) = try await response(request)
        let status = try json(data)
        guard status["receiver"] is [String: Any], status["device"] is [String: Any] else { throw LinkError.protocolMismatch }
        return status
    }

    static func rpc(_ address: String, token: String, op: String, params: [String: Any],
                    timeout: Double = 2) async throws -> [String: Any] {
        var body = params
        body["op"] = op
        var request = try request(address, path: "api/v1/rpc", token: token, timeout: timeout)
        try post(&request, body: body)
        let (data, _) = try await response(request)
        return try json(data)
    }

    static func screen(_ address: String, token: String) async throws -> Data {
        let request = try request(address, path: "api/v1/screen.jpg", token: token, timeout: 6)
        let (data, _) = try await response(request)
        return data
    }

    static func pointerSocket(_ address: String, token: String) throws -> URLSessionWebSocketTask {
        try socket(ProjectorConnection(address: address, token: token), path: "pointer/live")
    }

    static func socket(_ receiver: ProjectorConnection, path: String) throws -> URLSessionWebSocketTask {
        var request = try request(receiver.address, path: "api/v1/\(path)", token: receiver.token, timeout: 2)
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LinkError.notConnected
        }
        components.scheme = "ws"
        request.url = components.url
        request.setValue(receiver.address, forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_024
        socket.resume()
        return socket
    }

    static func post(_ receiver: ProjectorConnection, path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = try request(receiver.address, path: "api/v1/\(path)", token: receiver.token, timeout: 3)
        try post(&request, body: body)
        let (data, _) = try await response(request)
        return try json(data)
    }

    static func mirrorFrame(_ receiver: ProjectorConnection, id: String, jpeg: Data) async throws {
        var request = try request(receiver.address, path: "api/v1/mirror/frame", token: receiver.token, timeout: 1.5)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "X-BeamDeck-Request")
        request.setValue(id, forHTTPHeaderField: "X-BeamDeck-Mirror")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(jpeg.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = jpeg
        _ = try await response(request)
    }

    static func connectionFailed(_ error: Error) -> Bool {
        error is URLError || error as? LinkError == .remote("unauthorized") || error as? LinkError == .protocolMismatch
    }

    static func commandNotDelivered(_ error: Error) -> Bool {
        if let linkError = error as? LinkError {
            return linkError == .remote("unauthorized") || linkError == .notConnected
        }
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .notConnectedToInternet, .cannotFindHost].contains(error.code)
    }
}

private final class ReceiverSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private final class PointerStream {
    private var socket: URLSessionWebSocketTask?

    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// One unacknowledged event at a time keeps old motion out of the transport queue.
    func send(address: String, token: String, op: String, params: [String: Any]) async throws {
        let connection = try socket ?? WiFi.pointerSocket(address, token: token)
        socket = connection
        var message = params
        message["op"] = op
        let data = try JSONSerialization.data(withJSONObject: message)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { watchdog.cancel() }

        let reply: URLSessionWebSocketTask.Message
        do {
            try await connection.send(.string(String(decoding: data, as: UTF8.self)))
            reply = try await connection.receive()
        } catch {
            if socket === connection { close() }
            throw error
        }
        guard case .string(let json) = reply,
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            if socket === connection { close() }
            throw URLError(.cannotParseResponse)
        }
        if let code = object["error"] as? String { throw LinkError.remote(code) }
    }
}
