import SwiftUI

/// Projector settings over Bluetooth, through the built-in receiver only.
struct ProjectorView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var lumina: LuminaLink
    @State private var confirmDisconnect = false
    #if os(iOS)
    @AppStorage("liveRemote") private var liveRemote = true
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Проєктор", value: remote.projectorName)
                    LabeledContent("Стан", value: phaseText)
                    LabeledContent("Команд надіслано", value: "\(lumina.sentCount)")
                    LabeledContent("Підтверджено проєктором", value: "\(lumina.ackedCount)")
                    if let error = lumina.lastError {
                        LabeledContent("Остання помилка", value: error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Підключення")
                } footer: {
                    Text("Якщо «Підтверджено» росте, а проєктор не реагує, закрийте Lumina Go на інших телефонах.")
                }

                Section {
                    NavigationLink { MacrosListView() } label: {
                        Label("Макроси", systemImage: "wand.and.rays")
                    }
                    NavigationLink { KeystoneGuide() } label: {
                        Label("Трапеція і кути", systemImage: "trapezoid.and.line.vertical")
                    }
                    CoreRow("Налаштування проєктора", "gearshape", "settings")
                    CoreRow("Усі програми", "square.grid.2x2", "apps")
                    CoreRow("Джерело сигналу (HDMI)", "rectangle.on.rectangle", "input")
                    CoreRow("Трансляція з телефона", "airplayvideo", "cast")
                } header: {
                    Text("Проєктор")
                } footer: {
                    Text("Будь-яке меню, що відкрилося, гортайте пультом. Шлях до потрібного налаштування можна записати як макрос і потім відкривати одним дотиком.")
                }

                Section("Швидкий запуск") {
                    ForEach(Self.apps, id: \.id) { app in
                        Button { remote.launch(app.id) } label: { Label(app.label, systemImage: app.symbol) }
                    }
                }

                #if os(iOS)
                Section {
                    Toggle("Пульт на екрані блокування", isOn: $liveRemote)
                        .onChange(of: liveRemote) { _, _ in remote.refreshLiveRemote() }
                } footer: {
                    Text("Кнопки «Назад», «Додому», пауза й гучність на екрані блокування та в Dynamic Island, поки проєктор під’єднано.")
                }
                #endif

                Section {
                    Button("Від’єднатися від проєктора", role: .destructive) { confirmDisconnect = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Проєктор")
            .confirmationDialog("Від’єднатися?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Від’єднатися", role: .destructive) { remote.disconnect() }
            } message: {
                Text("Макроси збережуться.")
            }
        }
    }

    private var phaseText: String {
        switch lumina.phase {
        case .ready: "Під’єднано по Bluetooth"
        case .connecting: "Підключаємося…"
        case .scanning: "Шукаємо проєктор…"
        case .idle: "Не під’єднано"
        case .failed(let message): message
        }
    }

    /// The app shortcuts Lumina Go shows on screen.
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
    let key: String

    init(_ title: String, _ symbol: String, _ key: String) {
        self.title = title
        self.symbol = symbol
        self.key = key
    }

    var body: some View {
        Button { remote.key(key) } label: { Label(title, systemImage: symbol) }
    }
}

/// Keystone over Bluetooth: open the projector's own keystone menu, then adjust it with the D-pad here.
/// The receiver has no "set corner" command, and this firmware ignores the vendor keystone key.
struct KeystoneGuide: View {
    @EnvironmentObject private var remote: Remote
    @State private var recording = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                step(1, "Відкрийте трапецію на проєкторі")
                Button {
                    remote.key("settings")
                } label: {
                    Label("Відкрити налаштування", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Text("У налаштуваннях знайдіть «Проєкція» → «Трапеція» або «Корекція кутів».")
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

                step(3, "Наступного разу — одним дотиком")
                Button {
                    recording = true
                } label: {
                    Label("Записати шлях до трапеції як макрос", systemImage: "record.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .navigationTitle("Трапеція")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $recording) { MacroEditor(macro: Macro(name: "Трапеція", symbol: "trapezoid.and.line.vertical")) }
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
