import Foundation

/// One thing the remote can do, produced from a spoken phrase.
enum VoiceAction: Equatable {
    case key(String, times: Int)
    case volume(Int)
    case launch(id: String, label: String)
    case type(String)
    case search(String)
    case firmware(category: UInt8, action: UInt8, label: String)

    /// Short Ukrainian description shown under the microphone.
    var summary: String {
        switch self {
        case .key(let key, let times):
            let name = VoiceCommands.keyNames[key] ?? key
            return times > 1 ? "\(name) × \(times)" : name
        case .volume(let level): return "Гучність \(level)%"
        case .launch(_, let label): return "Відкрити \(label)"
        case .type(let text): return "Ввести «\(text)»"
        case .search(let query): return "Знайти на YouTube «\(query)»"
        case .firmware(_, _, let label): return label
        }
    }
}

/// Parses Ukrainian (plus common Russian/English) remote phrases on the device. No network, no model.
/// "вниз три рази і ок", "гучність 30", "відкрий ютуб", "знайди котики", "напиши привіт".
enum VoiceCommands {
    static func parse(_ phrase: String) -> [VoiceAction] {
        let text = normalize(phrase)
        guard !text.isEmpty else { return [] }

        // Free-text intents take the rest of the phrase, so they are checked before splitting.
        for (prefixes, make) in freeText {
            for prefix in prefixes where text.hasPrefix(prefix + " ") {
                let rest = String(text.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return [make(original(phrase, dropping: prefix.split(separator: " ").count))] }
            }
        }

        return text.components(separatedBy: " ")
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.joined(separator: " ") }
            .flatMap(parseClause)
    }

    // MARK: clauses

    private static func parseClause(_ clause: String) -> [VoiceAction] {
        let words = clause.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let times = count(in: words)

        if let level = volumeLevel(words) { return [.volume(level)] }

        if words.contains(where: { $0.hasPrefix("фокус") || $0.hasPrefix("резкіст") || $0.hasPrefix("різкіст") }) {
            if has(words, ["авто", "автоматично"]) { return [.key("autoFocus", times: 1)] }
            if has(words, ["ближче", "мінус", "менше", "назад"]) { return [.key("focusDown", times: times)] }
            if has(words, ["далі", "дальше", "плюс", "більше", "вперед"]) { return [.key("focusUp", times: times)] }
            return [.key("autoFocus", times: 1)]
        }
        if has(words, ["автофокус"]) { return [.key("autoFocus", times: 1)] }

        if let app = appShortcut(words) { return [app] }

        if has(words, ["перемотай", "перемотати", "перемотка"]) {
            return has(words, ["назад", "тому"])
                ? [.firmware(category: 7, action: 7, label: "Перемотати назад")]
                : [.firmware(category: 7, action: 8, label: "Перемотати вперед")]
        }

        for (key, stems) in keyStems where words.contains(where: { word in stems.contains { word.hasPrefix($0) } }) {
            return [.key(key, times: Self.repeatable.contains(key) ? times : 1)]
        }
        return []
    }

    // MARK: vocabulary

    private static let separators: Set<String> = ["і", "й", "та", "потім", "а", "и", "then", "and"]

    /// Checked in order: earlier entries win when a phrase matches several.
    private static let keyStems: [(String, [String])] = [
        ("mute", ["беззвуку", "заглуш", "mute"]),
        ("volumeUp", ["гучніше", "голосніше", "громче", "louder"]),
        ("volumeDown", ["тихіше", "тише", "quieter"]),
        ("power", ["вимкни проєктор", "вимкнути"]),
        ("standby", ["сон", "сну", "засни", "спати", "sleep"]),
        ("playPause", ["пауз", "зупини", "стоп", "грай", "відтвор", "продовж", "play", "pause"]),
        ("next", ["наступн", "далі", "next"]),
        ("previous", ["попередн", "previous"]),
        ("up", ["вгору", "вверх", "догори", "вище", "up"]),
        ("down", ["вниз", "донизу", "нижче", "down"]),
        ("left", ["вліво", "ліворуч", "наліво", "влево", "left"]),
        ("right", ["вправо", "праворуч", "направо", "right"]),
        ("ok", ["ок", "окей", "вибери", "вибрати", "обери", "натисни", "підтверд", "ентер", "ok", "enter"]),
        ("back", ["назад", "повернись", "поверни", "back"]),
        ("home", ["додому", "головн", "home"]),
        ("menu", ["меню", "menu"]),
        ("settings", ["налаштуван", "settings"]),
        ("keystone", ["трапец", "keystone"]),
        ("input", ["джерел", "hdmi", "source"]),
    ]

    private static let repeatable: Set<String> = ["up", "down", "left", "right", "volumeUp", "volumeDown", "back", "next", "previous"]

    static let keyNames: [String: String] = [
        "up": "Вгору", "down": "Вниз", "left": "Ліворуч", "right": "Праворуч", "ok": "OK", "back": "Назад",
        "home": "Додому", "menu": "Меню", "settings": "Налаштування", "volumeUp": "Гучніше", "volumeDown": "Тихіше",
        "mute": "Без звуку", "playPause": "Відтворення / пауза", "next": "Далі", "previous": "Попереднє",
        "focusUp": "Фокус далі", "focusDown": "Фокус ближче", "autoFocus": "Автофокус", "power": "Вимкнути проєктор",
        "standby": "Режим сну", "keystone": "Трапеція", "input": "Джерело сигналу",
    ]

    private static let apps: [(id: String, label: String, stems: [String])] = [
        ("lumina.youtube", "YouTube", ["ютуб", "youtube", "ютюб"]),
        ("lumina.netflix", "Netflix", ["нетфлікс", "netflix", "нетфликс"]),
        ("lumina.disney", "Disney+", ["дісней", "disney", "дисней"]),
        ("lumina.prime", "Prime Video", ["прайм", "prime", "амазон"]),
        ("lumina.browser", "Браузер", ["браузер", "інтернет", "browser"]),
        ("lumina.files", "Файли", ["файл", "провідник"]),
        ("lumina.music", "Музика", ["музик"]),
        ("lumina.video", "Відео", ["відео", "фільм"]),
        ("lumina.gallery", "Галерея", ["галере", "фото"]),
        ("lumina.usb", "USB", ["флешк", "usb", "юсб"]),
        ("lumina.store", "Магазин програм", ["магазин", "маркет", "плей"]),
    ]

    private static let openVerbs = ["відкрий", "відкрити", "запусти", "запустити", "увімкни", "включи", "open", "launch"]

    private static let freeText: [([String], (String) -> VoiceAction)] = [
        (["знайди на ютубі", "знайди на youtube", "пошук на ютубі", "знайди", "шукай", "пошукай", "пошук", "search"], { .search($0) }),
        (["напиши", "надрукуй", "введи", "набери", "type"], { .type($0) }),
    ]

    // MARK: helpers

    private static func appShortcut(_ words: [String]) -> VoiceAction? {
        // An app opens on "відкрий ютуб" or on its bare name; "пауза відео" stays a media key.
        guard words.contains(where: { openVerbs.contains($0) }) || words.count == 1 else { return nil }
        let joined = words.joined(separator: " ")
        return apps.first { app in app.stems.contains { joined.contains($0) } }
            .map { .launch(id: $0.id, label: $0.label) }
    }

    private static func volumeLevel(_ words: [String]) -> Int? {
        // Only the noun sets a level ("гучність 30"); "гучніше на 5" means five steps up.
        guard let index = words.firstIndex(where: { $0.hasPrefix("гучніст") || $0.hasPrefix("гучност") || $0 == "звук" || $0 == "volume" })
        else { return nil }
        var spoken: Int?
        for word in words[(index + 1)...] {
            if let value = Int(word.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) { return max(0, min(100, value)) }
            if let value = numbers[word] {
                // "двадцять п'ять" → 25: a ten followed by a unit adds up.
                if let tens = spoken, tens >= 20, tens % 10 == 0, value < 10 { return tens + value }
                spoken = value
            } else if spoken != nil { break }
        }
        if let spoken { return max(0, min(100, spoken)) }
        if words.contains(where: { ["максимум", "максимальна", "максимально"].contains($0) }) { return 100 }
        if words.contains(where: { ["половина", "наполовину"].contains($0) }) { return 50 }
        return nil
    }

    private static func count(in words: [String]) -> Int {
        if words.contains("двічі") { return 2 }
        if words.contains("тричі") { return 3 }
        for word in words {
            if let value = Int(word), (2...10).contains(value) { return value }
            if let value = numbers[word], (2...10).contains(value) { return value }
        }
        return 1
    }

    private static let numbers: [String: Int] = [
        "нуль": 0, "один": 1, "одна": 1, "одну": 1, "два": 2, "дві": 2, "три": 3, "чотири": 4, "п'ять": 5,
        "шість": 6, "сім": 7, "вісім": 8, "дев'ять": 9, "десять": 10, "двадцять": 20, "тридцять": 30,
        "сорок": 40, "п'ятдесят": 50, "шістдесят": 60, "сімдесят": 70, "вісімдесят": 80, "дев'яносто": 90, "сто": 100,
    ]

    private static func has(_ words: [String], _ any: [String]) -> Bool {
        words.contains { word in any.contains { word.hasPrefix($0) } }
    }

    /// Lowercase, unify apostrophes, drop punctuation, glue "без звуку" so it cannot read as "звук".
    static func normalize(_ phrase: String) -> String {
        var text = phrase.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "проектор", with: "проєктор")
        text = String(text.map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "%" ? $0 : " " })
        text = text.replacingOccurrences(of: "без звуку", with: "беззвуку")
            .replacingOccurrences(of: "вимкни звук", with: "беззвуку")
            .replacingOccurrences(of: "вимкнути звук", with: "беззвуку")
            .replacingOccurrences(of: "увімкни звук", with: "беззвуку")
            .replacingOccurrences(of: "вимкни проєктор", with: "вимкнути")
        return text.split(separator: " ").joined(separator: " ")
    }

    /// The spoken text after the trigger words, with the user's own capitalisation kept.
    private static func original(_ phrase: String, dropping words: Int) -> String {
        phrase.split(separator: " ").dropFirst(words).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
