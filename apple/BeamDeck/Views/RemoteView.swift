import SwiftUI

struct RemoteView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var lumina: LuminaLink
    @State private var keyboard = false
    @State private var voice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    DPad()
                    HStack(spacing: 18) {
                        RoundKey(symbol: "chevron.backward", label: "Назад", key: "back")
                        RoundKey(symbol: "house", label: "Додому", key: "home")
                        RoundKey(symbol: "line.3.horizontal", label: "Меню", key: "menu")
                    }
                    shortcuts
                    media
                    volume
                    FocusStrip()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .navigationTitle(remote.projectorName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button { voice = true } label: { Label("Голос", systemImage: "mic") }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    // Links open on the projector, any other text is typed into the focused field.
                    PasteButton(payloadType: String.self) { values in
                        Task { @MainActor in remote.deliver(values.first ?? "") }
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { keyboard = true } label: { Label("Клавіатура", systemImage: "keyboard") }
                }
                ToolbarItem(placement: .primaryAction) { PowerMenu() }
            }
            .sheet(isPresented: $keyboard) { KeyboardSheet() }
            #if os(iOS)
            .sheet(isPresented: $voice) { VoiceView() }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(remote.connected || remote.demo ? Color.green : .orange)
                .frame(width: 8, height: 8)
            Text(remote.demo ? "Демо" : remote.connected ? "Bluetooth" : "Повторне підключення…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    /// Projector screens Lumina Go also puts on its main remote, so every receiver handles them.
    private var shortcuts: some View {
        HStack(spacing: 0) {
            ShortcutKey(symbol: "gearshape", label: "Налаштув.", packet: [1, 9])
            ShortcutKey(symbol: "square.grid.2x2", label: "Програми", packet: [1, 10])
            ShortcutKey(symbol: "rectangle.on.rectangle", label: "Джерело", packet: [4, 5])
            ShortcutKey(symbol: "airplayvideo", label: "Трансляція", packet: [4, 30])
        }
        .padding(.vertical, 6)
        .background(Color.surface, in: .rect(cornerRadius: 22))
    }

    private var media: some View {
        HStack(spacing: 0) {
            MediaKey(symbol: "backward.fill", key: "previous")
            MediaKey(symbol: "playpause.fill", key: "playPause", large: true)
            MediaKey(symbol: "forward.fill", key: "next")
        }
        .padding(.vertical, 6)
        .background(Color.surface, in: .rect(cornerRadius: 22))
    }

    /// The receiver only takes relative volume, so there is no level to show.
    private var volume: some View {
        HStack(spacing: 10) {
            HoldKey(symbol: "speaker.minus", label: "Тихіше", key: "volumeDown")
            HoldKey(symbol: "speaker.slash", label: "Без звуку", key: "mute", repeats: false)
            HoldKey(symbol: "speaker.plus", label: "Гучніше", key: "volumeUp")
        }
        .padding(14)
        .background(Color.surface, in: .rect(cornerRadius: 22))
    }
}

struct ShortcutKey: View {
    @EnvironmentObject private var remote: Remote
    let symbol: String
    let label: String
    let packet: [UInt8]

    var body: some View {
        Button {
            remote.haptic += 1
            remote.send(packet)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .disabled(!remote.connected && !remote.demo)
        .accessibilityLabel(label)
    }
}

/// Click ring + swipe surface, like a hardware remote: tap a side or swipe, tap the centre for OK.
struct DPad: View {
    @EnvironmentObject private var remote: Remote
    @State private var pressed: String?
    @State private var repeatTask: Task<Void, Never>?
    @State private var repeated = false

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(Color.surface)
                ForEach(Array(arrows.enumerated()), id: \.offset) { _, arrow in
                    Image(systemName: arrow.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(pressed == arrow.key ? Color.accentColor : .secondary)
                        .offset(x: arrow.dx * size * 0.37, y: arrow.dy * size * 0.37)
                }
                Circle()
                    .fill(pressed == "ok" ? Color.accentColor.opacity(0.25) : Color.surfaceRaised)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .overlay(Text("OK").font(.title3.weight(.semibold)).foregroundStyle(.primary))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .frame(width: size, height: size)
            .scaleEffect(pressed == nil ? 1 : 0.985)
            .animation(.snappy(duration: 0.15), value: pressed)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressed == nil {
                        pressed = zone(value.startLocation, size: size)
                        startRepeat(pressed!)
                    } else if hypot(value.translation.width, value.translation.height) > 12, !repeated {
                        repeatTask?.cancel() // it is a swipe, not a hold
                    }
                }
                .onEnded { value in
                    repeatTask?.cancel()
                    if !repeated {
                        let moved = hypot(value.translation.width, value.translation.height) > 28
                        send(moved ? swipe(value.translation) : zone(value.startLocation, size: size))
                    }
                    pressed = nil
                    repeated = false
                })
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Навігація")
        .accessibilityHint("Проведіть вгору, вниз, ліворуч або праворуч. Двічі торкніться для OK.")
        .accessibilityAction { send("ok") }
        .accessibilityAdjustableAction { direction in send(direction == .increment ? "up" : "down") }
    }

    private struct Arrow { let key: String; let symbol: String; let dx: CGFloat; let dy: CGFloat }
    private let arrows = [
        Arrow(key: "up", symbol: "chevron.up", dx: 0, dy: -1), Arrow(key: "down", symbol: "chevron.down", dx: 0, dy: 1),
        Arrow(key: "left", symbol: "chevron.left", dx: -1, dy: 0), Arrow(key: "right", symbol: "chevron.right", dx: 1, dy: 0),
    ]

    private func zone(_ point: CGPoint, size: CGFloat) -> String {
        let dx = point.x - size / 2
        let dy = point.y - size / 2
        if hypot(dx, dy) < size * 0.19 { return "ok" }
        return abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
    }

    private func swipe(_ t: CGSize) -> String {
        abs(t.width) > abs(t.height) ? (t.width > 0 ? "right" : "left") : (t.height > 0 ? "down" : "up")
    }

    private func send(_ key: String) {
        remote.key(key)
    }

    /// Holding an arrow repeats it, for long lists; holding OK sends a long press.
    private func startRepeat(_ key: String) {
        repeatTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            repeated = true
            if key == "ok" {
                remote.key("ok", long: true)
                return
            }
            while !Task.isCancelled {
                send(key)
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }
}

struct RoundKey: View {
    @EnvironmentObject private var remote: Remote
    let symbol: String
    let label: String
    let key: String

    var body: some View {
        let available = remote.available(key)
        Button {
            remote.key(key)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 62, height: 62)
                    .background(Color.surface, in: .circle)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(available ? 1 : 0.45)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

struct MediaKey: View {
    @EnvironmentObject private var remote: Remote
    let symbol: String
    let key: String
    var large = false

    var body: some View {
        let available = remote.available(key)
        Button {
            remote.key(key)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: large ? 26 : 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(.rect)
                .opacity(available ? 1 : 0.4)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(key == "playPause" ? "Відтворення або пауза" : key == "next" ? "Далі" : "Назад")
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Lens focus; hold to keep the motor running.
struct FocusStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Фокус").font(.headline)
            HStack(spacing: 10) {
                HoldKey(symbol: "minus.magnifyingglass", label: "Ближче", key: "focusDown")
                HoldKey(symbol: "scope", label: "Авто", key: "autoFocus", repeats: false)
                HoldKey(symbol: "plus.magnifyingglass", label: "Далі", key: "focusUp")
            }
        }
        .padding(14)
        .background(Color.surface, in: .rect(cornerRadius: 22))
    }
}

struct HoldKey: View {
    @EnvironmentObject private var remote: Remote
    let symbol: String
    let label: String
    let key: String
    var repeats = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(task == nil ? Color.surfaceRaised : Color.accentColor.opacity(0.25), in: .rect(cornerRadius: 12))
            .opacity(remote.available(key) ? 1 : 0.45)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard task == nil else { return }
                    task = Task {
                        remote.key(key)
                        guard repeats else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled {
                            remote.key(key)
                            try? await Task.sleep(for: .milliseconds(180))
                        }
                    }
                }
                .onEnded { _ in task?.cancel(); task = nil })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { remote.key(key) }
    }
}

struct PowerMenu: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        Menu {
            Button { remote.key("standby") } label: { Label("Режим сну", systemImage: "moon") }
            Divider()
            Button(role: .destructive) { remote.key("power") } label: { Label("Вимкнути проєктор", systemImage: "power") }
        } label: {
            Label("Живлення", systemImage: "power")
        }
    }
}

struct KeyboardSheet: View {
    @EnvironmentObject private var remote: Remote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Текст або посилання", text: $text, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...5)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit(sendText)
                } footer: {
                    Text("Спершу виберіть текстове поле на проєкторі, наприклад пошук. Текст з’явиться в ньому.")
                }
                Section {
                    Button("Надіслати в поле", action: sendText).disabled(text.isEmpty)
                    Button("Відкрити як посилання") { remote.openLink(text); dismiss() }
                        .disabled(!(text.hasPrefix("http://") || text.hasPrefix("https://")))
                }
                Section {
                    Button { remote.deleteCharacter() } label: { Label("Стерти символ", systemImage: "delete.left") }
                    Button { remote.enter() } label: { Label("Enter", systemImage: "return") }
                    ForEach(Lumina.keyboardCommands) { command in
                        Button(command.title) { remote.command(command) }
                    }
                }
            }
            .navigationTitle("Клавіатура")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        remote.typeText(text)
        text = ""
    }
}
