import Foundation

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
                // The built-in receiver's percentage command is voice-only in Lumina Go; send it like Lumina does.
                command(.value("Гучність \(percent)%", 2, max(0, min(100, percent))))
            case .launch(let id, _):
                launch(id)
            case .type(let text):
                typeText(text)
            case .search(let query):
                openLink(Self.youtubeSearch(query))
            case .firmware(let category, let code, let label):
                command(.init(label, category, code))
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    static func youtubeSearch(_ query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return "https://www.youtube.com/results?search_query=\(encoded)"
    }
}
