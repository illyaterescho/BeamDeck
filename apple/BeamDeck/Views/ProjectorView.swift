import SwiftUI

struct ProjectorView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var link: BeamLink
    @EnvironmentObject private var lumina: LuminaLink
    @State private var keymap: [String: Int] = [:]
    @State private var sleep = 0
    @State private var confirmForget = false
    @State private var showBluetooth = false

    private let learnable: [(key: String, title: String)] = [
        ("focusUp", "Фокус: далі"), ("focusDown", "Фокус: ближче"), ("autoFocus", "Автофокус"),
        ("keystone", "Трапеція"), ("custom1", "Своя кнопка 1"), ("custom2", "Своя кнопка 2"),
    ]

    var body: some View {
        let status = remote.status
        NavigationStack {
            Form {
                Section("Підключення") {
                    LabeledContent("Проєктор", value: link.connectedName ?? lumina.connectedName ?? status.model)
                    LabeledContent("З’єднання", value: remote.connectionLabel)
                    if !status.android.isEmpty {
                        LabeledContent("Android", value: status.android)
                    }
                    if remote.wifiReady, let address = remote.wifiAddress {
                        LabeledContent("Адреса Wi-Fi", value: address.replacingOccurrences(of: "http://", with: ""))
                    }
                    Button("Підключення Bluetooth", systemImage: "dot.radiowaves.left.and.right") { showBluetooth = true }
                    Button("Вибрати інший проєктор") { remote.disconnect() }
                }

                Section("Зображення") {
                    NavigationLink { KeystoneView() } label: {
                        Label("Трапеція наживо", systemImage: "trapezoid.and.line.vertical")
                    }
                }

                if remote.hasReceiverSession || remote.demo {
                    if !remote.demo { firmwareSection }
                }
                if remote.firmware {
                    Section("Вбудоване керування") {
                        NavigationLink("Додаткові команди Bluetooth") { FirmwareControlsView() }
                    }
                }
                if remote.hasReceiverSession || remote.demo {
                    beamSections(status)
                } else if remote.firmware {
                    Section("Швидкі дії") {
                        Button("Налаштування проєктора", systemImage: "gearshape") { remote.key("settings") }
                        Button("Трапеція", systemImage: "trapezoid.and.line.vertical") { remote.key("keystone") }
                        Button("Своя кнопка 1", systemImage: "1.circle") { remote.key("custom1") }
                        Button("Своя кнопка 2", systemImage: "2.circle") { remote.key("custom2") }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Проєктор")
            .task(id: remote.receiverReady) { if remote.receiverReady { await loadKeymap() } }
            .onChange(of: status.learning?["state"] as? String) { _, _ in Task { await loadKeymap() } }
            .sheet(isPresented: $showBluetooth) { BluetoothConnectionsView() }
            .confirmationDialog("Забути проєктор?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Забути", role: .destructive) { remote.forgetProjector() }
            } message: {
                Text("Для повторного підключення знадобиться код з екрана проєктора.")
            }
        }
    }

    private var firmwareSection: some View {
        Section {
            if remote.firmware || remote.attachedFirmware != nil {
                LabeledContent("Вбудований Bluetooth", value: remote.firmware ? (lumina.connectedName ?? "Підключено") : "Недоступний")
                Button("Від’єднати вбудований Bluetooth") { remote.detachFirmware() }
            } else if !lumina.nearby.isEmpty {
                Menu("Додати вбудований Bluetooth") {
                    ForEach(lumina.nearby.sorted { $0.rssi > $1.rssi }) { device in
                        Button(device.name) { remote.attachFirmware(device.id) }
                    }
                }
            }
        } footer: {
            if !remote.firmware && remote.attachedFirmware == nil && !lumina.nearby.isEmpty {
                Text("Якщо тут є Bluetooth вашого проєктора, виберіть його один раз. BeamDeck запам’ятає його для тачпада, клавіатури й сумісних команд.")
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
                    Button { remote.send("open", ["destination": "player", "value": ""]) } label: {
                        Label("Програвач BeamDeck", systemImage: "play.rectangle")
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

private struct FirmwareControlsView: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        Form {
            Section("Зображення") {
                menu("Налаштування зображення", commands: Lumina.imageMenus)
                menu("Режим проєкції", commands: values(7, [
                    "Спереду зі столу", "Ззаду зі столу", "Спереду зі стелі", "Ззаду зі стелі",
                ]))
                menu("Формат екрана", commands: values(4, ["16:9", "4:3", "Авто"]))
                menu("Колірна температура", commands: values(3, ["Стандартна", "Холодна", "Тепла"]))
                menu("Режим яскравості", commands: values(6, ["Стандартний", "Еко", "Яскравий"]))
            }
            Section("Автоналаштування") {
                menu("Автофокус", commands: Lumina.Command.toggles(5))
                menu("Автоматична трапеція", commands: Lumina.Command.toggles(4))
                menu("Автокорекція чотирьох кутів", commands: Lumina.Command.toggles(6))
                menu("Розпізнавання екрана", commands: Lumina.Command.toggles(7))
                menu("Обхід перешкод", commands: Lumina.Command.toggles(8))
            }
            Section("Медіа й трансляція") {
                menu("Відтворення", commands: Lumina.mediaCommands)
                menu("Трансляція й динаміки", commands: Lumina.castingMenus)
                Button("Усі програми") { remote.firmwareCommand(.init("Усі програми", 11, 9)) }
                Button("Джерело сигналу") { remote.firmwareCommand(.init("Джерело сигналу", 4, 5)) }
            }
            Section {
                menu("Системні налаштування", commands: Lumina.settingsMenus)
                menu("Вимкнути проєктор через", commands: values(5, ["Таймер вимкнений", "15 хв", "30 хв", "60 хв", "120 хв"]))
                menu("Заставка", commands: [("5 хв", 300), ("10 хв", 600), ("20 хв", 1_200), ("60 хв", 3_600), ("Ніколи", 2_147_483_647)]
                    .map { .value($0.0, 9, $0.1) })
                menu("HDMI CEC", commands: Lumina.Command.toggles(10))
                menu("Звук кнопок", commands: Lumina.Command.toggles(3))
                menu("Автоматичний часовий пояс", commands: Lumina.Command.toggles(9))
            } header: {
                Text("Система")
            } footer: {
                Text("Доступність окремих команд залежить від прошивки проєктора.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Команди Bluetooth")
        .disabled(!remote.firmware)
    }

    private func menu(_ title: String, commands: [Lumina.Command]) -> some View {
        Menu(title) {
            ForEach(commands) { command in
                Button(command.title) { remote.firmwareCommand(command) }
            }
        }
    }

    private func values(_ action: UInt8, _ titles: [String]) -> [Lumina.Command] {
        titles.enumerated().map { .value($0.element, action, $0.offset) }
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
