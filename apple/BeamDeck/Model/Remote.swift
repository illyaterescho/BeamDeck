import Foundation
import SwiftUI

/// The phone side of the projector's built-in receiver. Everything goes over Bluetooth;
/// nothing is installed on the projector.
@MainActor
final class Remote: ObservableObject {
    let lumina = LuminaLink()
    @Published var notice: String?
    @Published var haptic = 0
    @Published private(set) var connected = false
    /// Last volume the user set; the receiver never reports the real level.
    @Published private(set) var volume: Int?
    /// Commands the user marked as working (true) or ignored (false) on this projector.
    @Published private(set) var compatibility: [String: Bool] = [:]

    /// `-demo` launch argument: try the interface without a projector.
    let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    private var noticeTask: Task<Void, Never>?
    private var selfTestRan = false
    private var lastVolumeSend = ContinuousClock.now
    private let savedKey = "lastLumina"

    init() {
        lumina.onPhaseChange = { [weak self] in self?.phaseChanged() }
        lumina.onWriteError = { [weak self] in self?.show("Проєктор не прийняв команду. Перевірте, що він поруч.") }
        // Reconnect to the last projector on launch, the way a hardware remote just works.
        if let saved = UserDefaults.standard.string(forKey: savedKey).flatMap(UUID.init(uuidString:)) {
            lumina.connect(saved)
            loadCompatibility(for: saved.uuidString)
        }
    }

    var hasSavedProjector: Bool { UserDefaults.standard.string(forKey: savedKey) != nil }

    /// Keep the remote on screen during brief reconnects instead of flashing the connect screen.
    var showRemote: Bool { demo || connected || (hasSavedProjector && lumina.phase == .connecting) }

    var projectorName: String { lumina.connectedName ?? "Проєктор" }

    func connect(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: savedKey)
        loadCompatibility(for: id.uuidString)
        lumina.connect(id)
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        lumina.disconnect()
        lumina.scan()
    }

    private func phaseChanged() {
        connected = lumina.connected
        if connected, volume == nil, let id = lumina.peripheralId,
           UserDefaults.standard.object(forKey: "volume:\(id)") != nil {
            volume = UserDefaults.standard.integer(forKey: "volume:\(id)")
        }
        if case .failed(let message) = lumina.phase { show(message) }
        if connected, ProcessInfo.processInfo.arguments.contains("-selftest"), !selfTestRan {
            selfTestRan = true
            Task { await selfTest() }
        }
    }

    /// `-selftest` launch argument: Home → Settings → Back, 3 s apart, to check the whole phone-to-projector path.
    private func selfTest() async {
        try? await Task.sleep(for: .seconds(1))
        for key in ["home", "settings", "back"] {
            print("[BeamDeck] selftest", key)
            self.key(key)
            try? await Task.sleep(for: .seconds(3))
        }
        print("[BeamDeck] selftest done: sent \(lumina.sentCount), acked \(lumina.ackedCount), error \(lumina.lastError ?? "none")")
    }

    // MARK: keys

    /// Core keys are the ones Lumina Go puts on screen, so every receiver handles them.
    func available(_ key: String) -> Bool {
        demo || (connected && Lumina.packet(forKey: key, long: false) != nil)
    }

    func key(_ name: String, long: Bool = false) {
        haptic += 1
        guard !demo else { return }
        guard let packet = Lumina.packet(forKey: name, long: long) else {
            show(Reason.text("unsupported"))
            return
        }
        send(packet)
    }

    func command(_ command: Lumina.Command) {
        haptic += 1
        guard !demo else { return }
        do { try lumina.send(command) } catch { show(error.localizedDescription) }
    }

    func send(_ packet: [UInt8], afterMotion: Bool = false) {
        guard !demo else { return }
        do { try lumina.send(packet, afterMotion: afterMotion) } catch { show(error.localizedDescription) }
    }

    // MARK: volume level

    /// Sets the volume in percent with the receiver's value command (meta "value:N", then [13, 2]).
    /// While dragging, sends at most every 200 ms; `final` always sends.
    func setVolume(_ percent: Int, final: Bool) {
        let percent = max(0, min(100, percent))
        volume = percent
        guard final || .now >= lastVolumeSend.advanced(by: .milliseconds(200)) else { return }
        lastVolumeSend = .now
        if final {
            UserDefaults.standard.set(percent, forKey: "volume:\(lumina.peripheralId ?? "")")
            haptic += 1
        }
        guard !demo else { return }
        do { try lumina.send(.value("Гучність", 2, percent)) } catch { show(error.localizedDescription) }
    }

    // MARK: mouse (category 7, told apart from media keys by packet length)

    func move(by delta: CGSize) { if !demo { lumina.move(by: delta) } }

    func click() {
        haptic += 1
        send([7, 2], afterMotion: true)
    }

    func rightClick() {
        haptic += 1
        send([7, 3], afterMotion: true)
    }

    func scroll(by amount: Double) {
        let step = max(-127, min(127, Int(amount / 18)))
        if step != 0 { send([7, 4, UInt8(bitPattern: Int8(step))]) }
    }

    func horizontalScroll(_ amount: Double) {
        let step = max(-127, min(127, Int(amount / 18)))
        if step != 0 { send([7, 7, UInt8(bitPattern: Int8(step))]) }
    }

    func pointerDown() {
        haptic += 1
        send([7, 5], afterMotion: true)
    }

    func pointerUp() { send([7, 6], afterMotion: true) }

    // MARK: text and links

    func typeText(_ text: String) {
        guard !demo, !text.isEmpty else { return }
        do { try lumina.sendText(String(text.prefix(1500))) } catch { show(error.localizedDescription) }
    }

    func deleteCharacter() { send([6, 1]) }
    func enter() { send([6, 2]) }

    /// Opens an http(s) link on the projector as a deep link.
    func openLink(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            show(Reason.text("invalid_url"))
            return
        }
        haptic += 1
        guard !demo else { return }
        do { try lumina.sendText(trimmed, deepLink: true) } catch { show(error.localizedDescription) }
    }

    /// Clipboard or shared content: links open, anything else is typed into the focused field.
    func deliver(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openLink(trimmed)
        } else {
            typeText(trimmed)
        }
    }

    func launch(_ id: String) {
        guard let shortcut = Lumina.shortcuts.first(where: { $0.id == id }) else {
            show(Reason.text("unsupported"))
            return
        }
        haptic += 1
        send(shortcut.packet)
    }

    // MARK: compatibility marks for extended commands

    func mark(_ commandId: String, works: Bool?) {
        compatibility[commandId] = works
        guard let id = lumina.peripheralId ?? UserDefaults.standard.string(forKey: savedKey) else { return }
        UserDefaults.standard.set(compatibility, forKey: "compat:\(id)")
    }

    private func loadCompatibility(for id: String) {
        compatibility = UserDefaults.standard.dictionary(forKey: "compat:\(id)") as? [String: Bool] ?? [:]
    }

    // MARK: notices

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
