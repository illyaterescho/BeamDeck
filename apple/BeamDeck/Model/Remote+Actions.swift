import Foundation

/// Higher-level actions built on the remote's existing routing (built-in receiver over BLE, or the Agent).
extension Remote {
    /// Runs spoken actions in order; repeated keys are spaced so the projector registers each press.
    func perform(_ actions: [VoiceAction]) async {
        for action in actions {
            switch action {
            case .key(let key, let times):
                for index in 0..<max(1, min(times, 10)) {
                    if index > 0 { try? await Task.sleep(for: .milliseconds(180)) }
                    self.key(key)
                }
            case .volume(let percent):
                if canSetVolume { setVolume(percent: percent) } else { show("Точну гучність цей проєктор не приймає.") }
            case .launch(let id, _):
                send("launch", ["appId": id])
            case .type(let text):
                send("text", ["action": "text", "text": text])
            case .search(let query):
                openLink(Self.youtubeSearch(query))
            case .firmware(let category, let code, let label):
                if firmware { firmwareCommand(.init(label, category, code)) }
                else { show("Ця дія доступна через вбудований приймач проєктора.") }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Opens an http(s) link on the projector: the built-in receiver takes it as a deep link.
    func openLink(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            show(Reason.text("invalid_url"))
            return
        }
        send("open", ["destination": "url", "value": trimmed])
    }

    /// Clipboard or shared content: links open, anything else is typed into the focused field.
    func deliver(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openLink(trimmed)
        } else {
            send("text", ["action": "text", "text": String(trimmed.prefix(1500))])
        }
    }

    // MARK: mouse extras (the built-in receiver's mouse protocol)

    /// Right click: a real right click on the built-in receiver, "back" on the Agent.
    func rightClick() {
        if firmware { firmwareRightClick() } else { key("back") }
    }

    func horizontalScroll(_ amount: Double) {
        if firmware { firmwareHorizontalScroll(amount) }
    }

    /// Press-and-drag: mouse down, moves, mouse up. Only the built-in receiver has a pressed state.
    var canDrag: Bool { firmware }

    func pointerDown() {
        guard firmware else { return }
        haptic += 1
        do { try lumina.send([7, 5], afterMotion: true) } catch { show(error.localizedDescription) }
    }

    func pointerUp() {
        guard firmware else { return }
        do { try lumina.send([7, 6], afterMotion: true) } catch { show(error.localizedDescription) }
    }

    static func youtubeSearch(_ query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return "https://www.youtube.com/results?search_query=\(encoded)"
    }
}
