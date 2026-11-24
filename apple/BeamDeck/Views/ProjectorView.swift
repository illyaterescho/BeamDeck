import SwiftUI

struct ProjectorView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var link: BeamLink
    @State private var keymap: [String: Int] = [:]
    @State private var sleep = 0
    @State private var confirmForget = false

    private let learnable: [(key: String, title: String)] = [
        ("focusUp", "Фокус: далі"), ("focusDown", "Фокус: ближче"), ("autoFocus", "Автофокус"),
        ("keystone", "Трапеція"), ("custom1", "Своя кнопка 1"), ("custom2", "Своя кнопка 2"),
    ]

    var body: some View {
        let status = remote.status
        NavigationStack {
            Form {
                if remote.firmware {
                    Section {
                        LabeledContent("Приймач", value: remote.lumina.connectedName ?? "Вбудований у проєктор")
                        Button("Від’єднатися", role: .destructive) { remote.lumina.disconnect() }
                    } header: {
                        Text("Підключення")
                    } footer: {
                        Text("Команди виконує вбудований приймач проєктора. Доступні навігація, фокус, гучність, живлення й медіа. Запуск програм і живе зображення екрана потребують приймача BeamDeck.")
                    }
                } else {
                    Section("Підключення") {
                        LabeledContent("Проєктор", value: link.connectedName ?? status.model)
                        LabeledContent("Android", value: status.android)
                        LabeledContent("Wi-Fi", value: status.lan?.replacingOccurrences(of: "http://", with: "") ?? "Не під’єднано")
                    }
                }

                if !remote.firmware {
                beamSections(status)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Проєктор")
            .task { if !remote.firmware { await loadKeymap() } }
            .onChange(of: status.learning?["state"] as? String) { _, _ in Task { await loadKeymap() } }
            .confirmationDialog("Забути проєктор?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Забути", role: .destructive) { link.forgetCurrent() }
            } message: {
                Text("Для повторного підключення знадобиться код з екрана проєктора.")
            }
        }
    }

    @ViewBuilder private func beamSections(_ status: ProjectorStatus) -> some View {
                Section {
                    Health(title: "Системні кнопки", detail: adbText(status.adb), ok: status.adb == "ready",
                           waiting: status.adb == "authorizing")
                    Health(title: "Навігація", detail: status.accessibility ? "Служба активна" : "Увімкніть «BeamDeck · Навігація»",
                           ok: status.accessibility)
                    Health(title: "Клавіатура", detail: status.keyboard == "ready" ? "Готова" : Reason.text(status.keyboard),
                           ok: status.keyboard == "ready")
                    Health(title: "Медіа", detail: status.reason("playPause").map(Reason.text) ?? "Готово",
                           ok: status.available("playPause"))
                    if status.adb != "ready" {
                        Button("Перевірити ще раз") { remote.send("adb") }
                    }
                } header: {
                    Text("Можливості приймача")
                } footer: {
                    if status.adb != "ready" {
                        Text("Для фокуса, меню й живлення на проєкторі відкрийте «Налаштування → Про пристрій», сім разів натисніть «Номер збірки», потім у «Для розробників» увімкніть налагодження USB або по мережі. Коли з’явиться запит, позначте «Завжди дозволяти» і натисніть OK.")
                    }
                }

                Section {
                    ForEach(learnable, id: \.key) { item in
                        LearnRow(key: item.key, title: item.title, code: keymap[item.key]) { await loadKeymap() }
                    }
                } header: {
                    Text("Кнопки пульта проєктора")
                } footer: {
                    Text("Натисніть «Навчити», потім відповідну кнопку на фізичному пульті. BeamDeck запам’ятає її й зможе натискати сам.")
                }

                Section("Таймер сну") {
                    Picker("Вимкнути звук через", selection: $sleep) {
                        Text("Вимкнено").tag(0)
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) хв").tag($0) }
                    }
                    .onChange(of: sleep) { _, minutes in remote.send("sleep", ["minutes": minutes]) }
                    if let remaining = status.sleepRemaining {
                        LabeledContent("Залишилось", value: Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))
                    }
                }

                Section("Інструменти") {
                    Button { remote.send("open", ["destination": "settings", "value": ""]) } label: {
                        Label("Налаштування проєктора", systemImage: "gearshape")
                    }
                    Button { remote.send("open", ["destination": "grid", "value": ""]) } label: {
                        Label("Тестова сітка", systemImage: "squareshape.split.3x3")
                    }
                    Button { remote.key("keystone") } label: { Label("Трапеція", systemImage: "trapezoid.and.line.vertical") }
                        .disabled(!status.available("keystone"))
                    Button { remote.key("custom1") } label: { Label("Своя кнопка 1", systemImage: "1.circle") }
                        .disabled(!status.available("custom1"))
                    Button { remote.key("custom2") } label: { Label("Своя кнопка 2", systemImage: "2.circle") }
                        .disabled(!status.available("custom2"))
                }

                Section {
                    Button("Від’єднатися й забути цей проєктор", role: .destructive) { confirmForget = true }
                }
    }

    private func adbText(_ state: String) -> String {
        switch state {
        case "ready": "Фокус, меню й живлення доступні"
        case "authorizing": "Підтвердьте запит на екрані проєктора"
        default: "Потрібне налагодження по мережі"
        }
    }

    private func loadKeymap() async {
        guard let reply = try? await remote.call("keymap"), let keys = reply["keys"] as? [String: [String: Any]] else { return }
        keymap = keys.compactMapValues { entry in (entry["learned"] as? Bool == true) ? entry["code"] as? Int : nil }
    }
}

struct Health: View {
    let title: String
    let detail: String
    let ok: Bool
    var waiting = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : waiting ? "clock.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : waiting ? .orange : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LearnRow: View {
    @EnvironmentObject private var remote: Remote
    let key: String
    let title: String
    let code: Int?
    let reload: () async -> Void

    private var listening: Bool {
        let learning = remote.status.learning
        return learning?["key"] as? String == key && learning?["state"] as? String == "listening"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(listening ? "Натисніть кнопку на пульті проєктора…" : code.map { "Код клавіші \($0)" } ?? "Не навчено")
                    .font(.footnote)
                    .foregroundStyle(listening ? Color.accentColor : .secondary)
            }
            Spacer()
            if listening {
                ProgressView()
            } else {
                Button(code == nil ? "Навчити" : "Змінити") { remote.send("learn", ["key": key]) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .swipeActions {
            if code != nil {
                Button("Скинути", role: .destructive) {
                    Task { _ = try? await remote.call("forget", ["key": key]); await reload() }
                }
            }
        }
    }
}
