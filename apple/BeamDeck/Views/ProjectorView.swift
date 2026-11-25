import SwiftUI

/// Projector settings over Bluetooth, through the built-in receiver only.
struct ProjectorView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var lumina: LuminaLink
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Підключення") {
                    LabeledContent("Проєктор", value: remote.projectorName)
                    LabeledContent("Стан", value: remote.connected ? "Під’єднано по Bluetooth" : "Підключаємося…")
                }

                Section {
                    NavigationLink { KeystoneGuide() } label: {
                        Label("Трапеція і кути", systemImage: "trapezoid.and.line.vertical")
                    }
                    CoreRow("Налаштування проєктора", "gearshape", [1, 9])
                    CoreRow("Усі програми", "square.grid.2x2", [1, 10])
                    CoreRow("Джерело сигналу (HDMI)", "rectangle.on.rectangle", [4, 5])
                    CoreRow("Трансляція з телефона", "airplayvideo", [4, 30])
                } header: {
                    Text("Проєктор")
                } footer: {
                    Text("Ці команди працюють на будь-якому проєкторі з вбудованим приймачем. Меню, що відкрилося, гортайте пультом або D-pad’ом у розділі «Трапеція».")
                }

                Section("Швидкий запуск") {
                    ForEach(Self.apps, id: \.id) { app in
                        Button { remote.launch(app.id) } label: { Label(app.label, systemImage: app.symbol) }
                    }
                }

                ExtendedCommands()

                Section {
                    Button("Від’єднатися від проєктора", role: .destructive) { confirmDisconnect = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Проєктор")
            .confirmationDialog("Від’єднатися?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Від’єднатися", role: .destructive) { remote.disconnect() }
            } message: {
                Text("Позначки, які команди працюють, збережуться.")
            }
        }
    }

    /// The app shortcuts Lumina Go shows on screen (category 4); other shortcuts are voice-only there.
    private static let apps: [(id: String, label: String, symbol: String)] = [
        ("lumina.youtube", "YouTube", "play.rectangle"),
        ("lumina.netflix", "Netflix", "film"),
        ("lumina.disney", "Disney+", "sparkles.tv"),
        ("lumina.prime", "Prime Video", "tv"),
        ("lumina.usb", "USB-накопичувач", "externaldrive"),
    ]
}

private struct CoreRow: View {
    @EnvironmentObject private var remote: Remote
    let title: String
    let symbol: String
    let packet: [UInt8]

    init(_ title: String, _ symbol: String, _ packet: [UInt8]) {
        self.title = title
        self.symbol = symbol
        self.packet = packet
    }

    var body: some View {
        Button {
            remote.haptic += 1
            remote.send(packet)
        } label: { Label(title, systemImage: symbol) }
    }
}

/// Keystone over Bluetooth: open the projector's own keystone menu, then adjust it with the D-pad here.
/// The receiver has no "set corner" command, so this is the reliable way on every firmware.
struct KeystoneGuide: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                step(1, "Відкрийте трапецію на проєкторі")
                HStack(spacing: 10) {
                    ExtendedButton(.init("Кнопка трапеції", 4, 16), symbol: "trapezoid.and.line.vertical")
                    Button {
                        remote.haptic += 1
                        remote.send([1, 9])
                    } label: {
                        Label("Через налаштування", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Якщо кнопка трапеції не спрацювала, відкрийте «Налаштування» й знайдіть «Проєкція» → «Трапеція» або «Корекція кутів».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                step(2, "Регулюйте стрілками")
                DPad()
                HStack(spacing: 18) {
                    RoundKey(symbol: "chevron.backward", label: "Назад", key: "back")
                    RoundKey(symbol: "house", label: "Додому", key: "home")
                    RoundKey(symbol: "line.3.horizontal", label: "Меню", key: "menu")
                }
                .frame(maxWidth: .infinity)

                step(3, "Додатково")
                HStack(spacing: 10) {
                    ExtendedButton(.init("Скинути трапецію", 4, 28), symbol: "arrow.counterclockwise")
                    ExtendedButton(.init("Режим кутів", 4, 29), symbol: "square.dashed")
                }
                HStack(spacing: 10) {
                    ExtendedButton(.init("Автотрапеція: увімк.", 12, 4, metadata: "toggle:on"), symbol: "wand.and.stars")
                    ExtendedButton(.init("Автотрапеція: вимк.", 12, 4, metadata: "toggle:off"), symbol: "wand.and.stars.inverse")
                }
                Text("Ці кнопки не всі прошивки підтримують. Після натискання позначте, чи спрацювало.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Трапеція")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.18), in: .circle)
            Text(title).font(.headline)
        }
    }
}

/// A command that some firmwares ignore: after sending, ask whether it worked and remember the answer.
private struct ExtendedButton: View {
    @EnvironmentObject private var remote: Remote
    let command: Lumina.Command
    let symbol: String
    @State private var asking = false

    init(_ command: Lumina.Command, symbol: String) {
        self.command = command
        self.symbol = symbol
    }

    var body: some View {
        let mark = remote.compatibility[command.id]
        Button {
            remote.command(command)
            if mark == nil { asking = true }
        } label: {
            Label(command.title, systemImage: mark == false ? "xmark.circle" : symbol)
                .font(.subheadline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .opacity(mark == false ? 0.5 : 1)
        .confirmationDialog("«\(command.title)» спрацювало?", isPresented: $asking, titleVisibility: .visible) {
            Button("Так, працює") { remote.mark(command.id, works: true) }
            Button("Ні, проєктор не відреагував") { remote.mark(command.id, works: false) }
            Button("Ще не знаю", role: .cancel) {}
        }
    }
}

/// Everything Lumina Go only offers by voice: brightness, colour, projection, auto features, settings pages.
/// The user marks what works; ignored commands move to a collapsed group.
private struct ExtendedCommands: View {
    @EnvironmentObject private var remote: Remote
    @State private var showIgnored = false

    var body: some View {
        let groups = Self.groups
        let ignored = groups.flatMap(\.commands).filter { remote.compatibility[$0.id] == false }
        Section {
            ForEach(groups, id: \.title) { group in
                let visible = group.commands.filter { remote.compatibility[$0.id] != false }
                if !visible.isEmpty {
                    DisclosureGroup(group.title) {
                        ForEach(visible) { command in ExtendedRow(command: command) }
                    }
                }
            }
            if !ignored.isEmpty {
                DisclosureGroup("Не працюють на цьому проєкторі (\(ignored.count))", isExpanded: $showIgnored) {
                    ForEach(ignored) { command in
                        HStack {
                            Text(command.title).foregroundStyle(.secondary)
                            Spacer()
                            Button("Повернути") { remote.mark(command.id, works: nil) }.font(.footnote)
                        }
                    }
                }
            }
        } header: {
            Text("Розширені команди")
        } footer: {
            Text("У Lumina Go ці команди є лише голосом, і частина прошивок їх ігнорує. Натисніть, подивіться на проєктор і позначте результат. Те, що не працює, сховається.")
        }
    }

    private struct Group { let title: String; let commands: [Lumina.Command] }

    private static func values(_ action: UInt8, _ titles: [String], prefix: String) -> [Lumina.Command] {
        titles.enumerated().map { .value("\(prefix): \($0.element)", action, $0.offset) }
    }

    private static func toggle(_ action: UInt8, _ title: String) -> [Lumina.Command] {
        [.init("\(title): увімк.", 12, action, metadata: "toggle:on"), .init("\(title): вимк.", 12, action, metadata: "toggle:off")]
    }

    /// Values match Lumina Go's own voice table (verified against the app).
    private static let groups: [Group] = [
        Group(title: "Зображення", commands:
            values(6, ["Стандартний", "Еко", "Яскравий"], prefix: "Яскравість")
            + values(3, ["Стандартна", "Холодна", "Тепла"], prefix: "Колір")
            + values(4, ["16:9", "4:3", "Авто"], prefix: "Формат")
            + [.init("Збільшити масштаб", 4, 8), .init("Зменшити масштаб", 4, 9)]),
        Group(title: "Режим проєкції", commands:
            values(7, ["Спереду, стіл", "Ззаду, стіл", "Спереду, стеля", "Ззаду, стеля"], prefix: "Проєкція")),
        Group(title: "Автоналаштування", commands:
            [.init("Автофокус зараз", 4, 3)]
            + toggle(5, "Автофокус") + toggle(6, "Автокорекція кутів")
            + toggle(7, "Розпізнавання екрана") + toggle(8, "Обхід перешкод")),
        Group(title: "Звук і система", commands:
            values(5, ["вимкнено", "15 хв", "30 хв", "60 хв", "120 хв"], prefix: "Таймер сну")
            + toggle(10, "HDMI CEC") + toggle(3, "Звук кнопок") + toggle(9, "Автоматичний часовий пояс")
            + [.init("Аудіорежим", 11, 11), .init("Bluetooth-колонка", 4, 15)]),
        Group(title: "Сторінки налаштувань", commands: [
            .init("Wi-Fi", 9, 1), .init("Bluetooth", 9, 2), .init("Екран", 9, 3), .init("Звук", 9, 4),
            .init("Мова", 9, 5), .init("Дата й час", 9, 6), .init("Програми", 9, 7), .init("Сховище", 9, 8),
            .init("Мережа", 9, 9), .init("Про пристрій", 9, 11), .init("Корекція трапеції", 11, 12),
            .init("Налаштування дисплея", 11, 19), .init("Живлення", 11, 10), .init("Інформація про проєктор", 4, 19),
        ]),
        Group(title: "Трансляція", commands: [
            .init("AirPlay", 4, 17), .init("Miracast", 4, 18), .init("eShare / дублювання", 11, 8),
        ]),
    ]
}

private struct ExtendedRow: View {
    @EnvironmentObject private var remote: Remote
    let command: Lumina.Command
    @State private var asking = false

    var body: some View {
        let mark = remote.compatibility[command.id]
        Button {
            remote.command(command)
            if mark == nil { asking = true }
        } label: {
            HStack {
                Text(command.title).foregroundStyle(.primary)
                Spacer()
                if mark == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .confirmationDialog("«\(command.title)» спрацювало?", isPresented: $asking, titleVisibility: .visible) {
            Button("Так, працює") { remote.mark(command.id, works: true) }
            Button("Ні, проєктор не відреагував") { remote.mark(command.id, works: false) }
            Button("Ще не знаю", role: .cancel) {}
        }
    }
}
