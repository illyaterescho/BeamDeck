// Run: swiftc -o /tmp/voicetest apple/BeamDeck/Model/VoiceCommands.swift apple/Tools/VoiceCommandsTests.swift && /tmp/voicetest
import Foundation

@main
struct VoiceCommandsTests {
    static func main() {
        let cases: [(String, [VoiceAction])] = [
            ("вниз", [.key("down", times: 1)]),
            ("Вниз три рази", [.key("down", times: 3)]),
            ("вниз 4", [.key("down", times: 4)]),
            ("тричі вправо", [.key("right", times: 3)]),
            ("вниз три рази і ок", [.key("down", times: 3), .key("ok", times: 1)]),
            ("вліво потім вибери", [.key("left", times: 1), .key("ok", times: 1)]),
            ("Назад.", [.key("back", times: 1)]),
            ("на головну", [.key("home", times: 1)]),
            ("гучніше", [.key("volumeUp", times: 1)]),
            ("гучніше на 5", [.key("volumeUp", times: 5)]),
            ("тихіше двічі", [.key("volumeDown", times: 2)]),
            ("гучність 30", [.volume(30)]),
            ("гучність тридцять", [.volume(30)]),
            ("гучність двадцять п’ять", [.volume(25)]),
            ("гучність на максимум", [.volume(100)]),
            ("без звуку", [.key("mute", times: 1)]),
            ("вимкни звук", [.key("mute", times: 1)]),
            ("пауза", [.key("playPause", times: 1)]),
            ("пауза відео", [.key("playPause", times: 1)]),
            ("наступне", [.key("next", times: 1)]),
            ("перемотай назад", [.firmware(category: 7, action: 7, label: "Перемотати назад")]),
            ("фокус ближче", [.key("focusDown", times: 1)]),
            ("фокус далі два рази", [.key("focusUp", times: 2)]),
            ("автофокус", [.key("autoFocus", times: 1)]),
            ("відкрий ютуб", [.launch(id: "lumina.youtube", label: "YouTube")]),
            ("запусти Netflix", [.launch(id: "lumina.netflix", label: "Netflix")]),
            ("браузер", [.launch(id: "lumina.browser", label: "Браузер")]),
            ("знайди котики смішні", [.search("котики смішні")]),
            ("Знайди на ютубі Дюна 2", [.search("Дюна 2")]),
            ("напиши Привіт, світ", [.type("Привіт, світ")]),
            ("вимкни проектор", [.key("power", times: 1)]),
            ("режим сну", [.key("standby", times: 1)]),
            ("трапеція", [.key("keystone", times: 1)]),
            ("щось незрозуміле", []),
        ]
        var failed = 0
        for (phrase, expected) in cases {
            let actual = VoiceCommands.parse(phrase)
            if actual != expected {
                failed += 1
                print("FAIL «\(phrase)»\n  expected \(expected)\n  actual   \(actual)")
            }
        }
        print(failed == 0 ? "OK: \(cases.count) phrases" : "\(failed) of \(cases.count) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
