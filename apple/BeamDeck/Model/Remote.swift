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
    @Published var status = ProjectorStatus()
    @Published var notice: String?
    @Published var apps: [LaunchableApp] = []
    @Published var haptic = 0

    private var pointer = CGSize.zero
    private var pointerInFlight = false
    private var noticeTask: Task<Void, Never>?

    /// `-demo` launch argument: a sample projector, for trying the interface without hardware.
    let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    init() {
        if demo { status = ProjectorStatus(raw: Self.sample) }
        link.onStatus = { [weak self] in self?.status = ProjectorStatus(raw: $0) }
        link.onReady = { [weak self] in Task { await self?.refresh() } }
    }

    var ready: Bool { link.phase == .ready }

    func refresh() async {
        if let reply = try? await link.request("status") { status = ProjectorStatus(raw: reply) }
    }

    /// Fire-and-report: errors surface as a short notice instead of an alert.
    func send(_ op: String, _ params: [String: Any] = [:]) {
        haptic += 1
        Task {
            do {
                let reply = try await call(op, params)
                if let volume = reply["volume"] as? [String: Any] {
                    var raw = status.raw
                    raw["volume"] = volume
                    status = ProjectorStatus(raw: raw)
                }
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func key(_ name: String, long: Bool = false) {
        send("key", long ? ["key": name, "long": true] : ["key": name])
    }

    @discardableResult
    func call(_ op: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        if demo { return op == "apps" ? ["apps": Self.sampleApps] : [:] }
        if ready { return try await link.request(op, params) }
        return try await WiFi.rpc(status.lan, token: link.token, op: op, params: params)
    }

    func loadApps() async {
        guard let reply = try? await call("apps"), let list = reply["apps"] as? [[String: Any]] else { return }
        apps = list.compactMap { entry in
            guard let id = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
            return LaunchableApp(id: id, label: label)
        }
    }

    /// Touchpad deltas are coalesced so a slow link never builds a queue of stale moves.
    func move(by delta: CGSize) {
        pointer.width += delta.width
        pointer.height += delta.height
        flushPointer()
    }

    private func flushPointer() {
        guard !pointerInFlight, pointer != .zero else { return }
        let delta = pointer
        pointer = .zero
        pointerInFlight = true
        Task {
            defer { pointerInFlight = false; flushPointer() }
            do { _ = try await call("pointer", ["dx": Double(delta.width), "dy": Double(delta.height)]) }
            catch { show(error.localizedDescription) }
        }
    }

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

/// Wi-Fi path to the same receiver: used for the screen preview and as a fallback when BLE drops.
enum WiFi {
    static func endpoint(_ lan: String?, _ path: String) -> URL? {
        guard let lan, let base = URL(string: lan) else { return nil }
        return base.appending(path: path)
    }

    static func request(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 6)
        if let token { request.setValue("BeamDeckSession=\(token)", forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        return request
    }

    static func rpc(_ lan: String?, token: String?, op: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = endpoint(lan, "api/v1/rpc"), token != nil else { throw LinkError.notConnected }
        var body = params
        body["op"] = op
        var request = request(url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-BeamDeck-Request")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LinkError.protocolMismatch }
        if let error = object["error"] as? [String: Any] { throw LinkError.remote(error["code"] as? String ?? "") }
        return object
    }

    static func screen(_ lan: String?, token: String?) async throws -> Data {
        guard let url = endpoint(lan, "api/v1/screen.jpg") else { throw LinkError.notConnected }
        let (data, response) = try await URLSession.shared.data(for: request(url, token: token))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["code"] as? String
            throw LinkError.remote(code ?? "adb_required")
        }
        return data
    }
}
