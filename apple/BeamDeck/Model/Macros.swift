import Foundation

/// A recorded path of remote keys, e.g. Settings → ↓ ↓ → OK, replayed with one tap.
/// This is how menus the receiver cannot open directly (keystone, picture mode…) become one button.
struct Macro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String = "wand.and.rays"
    var steps: [String] = []
    /// Pause between keys; projector menus need time to animate.
    var pauseMs: Int = 500
}

@MainActor
final class MacroStore: ObservableObject {
    @Published private(set) var macros: [Macro] = []
    @Published private(set) var playing: UUID?
    private var task: Task<Void, Never>?
    private let key = "macros.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Macro].self, from: data) {
            macros = saved
        }
    }

    func save(_ macro: Macro) {
        if let index = macros.firstIndex(where: { $0.id == macro.id }) { macros[index] = macro } else { macros.append(macro) }
        persist()
    }

    func delete(_ id: UUID) {
        macros.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        macros.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(macros) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Plays the steps in order; tapping a playing macro stops it.
    func play(_ macro: Macro, on remote: Remote) {
        if playing == macro.id { stop(); return }
        stop()
        playing = macro.id
        task = Task {
            for (index, step) in macro.steps.enumerated() {
                guard !Task.isCancelled else { break }
                if index > 0 { try? await Task.sleep(for: .milliseconds(macro.pauseMs)) }
                guard !Task.isCancelled else { break }
                remote.key(step)
            }
            if !Task.isCancelled { playing = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        playing = nil
    }

    /// Voice: "макрос трапеція" or just the macro's name.
    func match(_ phrase: String) -> Macro? {
        let text = VoiceCommands.normalize(phrase).replacingOccurrences(of: "макрос ", with: "")
        guard !text.isEmpty else { return nil }
        return macros.first { VoiceCommands.normalize($0.name) == text }
            ?? macros.first { text.contains(VoiceCommands.normalize($0.name)) && phrase.lowercased().contains("макрос") }
    }

    /// Keys a macro can record, with labels and symbols for the recorder pad.
    static let keys: [(key: String, label: String, symbol: String)] = [
        ("up", "Вгору", "chevron.up"), ("down", "Вниз", "chevron.down"),
        ("left", "Ліворуч", "chevron.left"), ("right", "Праворуч", "chevron.right"),
        ("ok", "OK", "circle.circle"), ("back", "Назад", "chevron.backward"),
        ("home", "Додому", "house"), ("menu", "Меню", "line.3.horizontal"),
        ("settings", "Налаштування", "gearshape"), ("apps", "Програми", "square.grid.2x2"),
        ("input", "Джерело", "rectangle.on.rectangle"), ("cast", "Трансляція", "airplayvideo"),
        ("volumeDown", "Тихіше", "speaker.minus"), ("volumeUp", "Гучніше", "speaker.plus"),
        ("mute", "Без звуку", "speaker.slash"), ("playPause", "Пауза", "playpause"),
        ("focusDown", "Фокус −", "minus.magnifyingglass"), ("focusUp", "Фокус +", "plus.magnifyingglass"),
    ]

    static func label(_ key: String) -> String { keys.first { $0.key == key }?.label ?? key }
    static func symbol(_ key: String) -> String { keys.first { $0.key == key }?.symbol ?? "circle" }
}
