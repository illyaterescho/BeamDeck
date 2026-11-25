import SwiftUI

struct RemoteView: View {
    @EnvironmentObject private var remote: Remote
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
                    media
                    volume
                    FocusStrip()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .navigationTitle(remote.status.model)
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
            Circle().fill(remote.receiverReady || remote.firmware || remote.demo ? Color.green : .orange)
                .frame(width: 8, height: 8)
            Text(remote.connectionLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if let app = remote.status.nowPlayingApp {
                Label(app, systemImage: remote.status.playing ? "play.fill" : "pause.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 4)
    }

    private var media: some View {
        HStack(spacing: 0) {
            MediaKey(symbol: "backward.fill", key: "previous")
            MediaKey(symbol: remote.status.playing ? "pause.fill" : "playpause.fill", key: "playPause", large: true)
            MediaKey(symbol: "forward.fill", key: "next")
        }
        .padding(.vertical, 6)
        .background(Color.surface, in: .rect(cornerRadius: 22))
    }

    private var volume: some View {
        let status = remote.status
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                RoundKey(symbol: "speaker.minus", label: "Тихіше", key: "volumeDown")
                VolumeSlider()
                RoundKey(symbol: "speaker.plus", label: "Голосніше", key: "volumeUp")
            }
            HStack {
                Button { remote.key("mute") } label: {
                    Label(status.muted ? "Увімкнути звук" : "Звук",
                          systemImage: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(minHeight: 35)
                }
                .disabled(!status.available("mute"))
                .accessibilityLabel(status.muted ? "Увімкнути звук" : "Вимкнути звук")
                Spacer()
                if let percent = remote.volumePercent {
                    Text(remote.volumeIsEstimated ? "≈\(percent)%" : "\(percent)%").monospacedDigit()
                } else if remote.volumeIsEstimated {
                    Text("Рівень не зчитується")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.surface, in: .rect(cornerRadius: 22))
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
        guard remote.status.available(key) else {
            remote.show(Reason.text(remote.status.reason(key) ?? ""))
            return
        }
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
        let available = remote.status.available(key)
        Button {
            if available { remote.key(key) } else { remote.show(Reason.text(remote.status.reason(key) ?? "")) }
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
        let available = remote.status.available(key)
        Button {
            if available { remote.key(key) } else { remote.show(Reason.text(remote.status.reason(key) ?? "")) }
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

struct VolumeSlider: View {
    @EnvironmentObject private var remote: Remote
    @State private var draft: Int?
    @State private var editing = false
    @State private var lastPreview: Int?
    @State private var nextPreview = ContinuousClock.now

    var body: some View {
        Slider(value: Binding(
            get: { Double(draft ?? remote.volumePercent ?? 0) },
            set: { value in update(Int(value.rounded())) }
        ), in: 0...100, step: 1) { editing in
            self.editing = editing
            if editing {
                lastPreview = nil
                nextPreview = .now
            } else {
                if let draft, draft != lastPreview { remote.setVolume(percent: draft) }
                draft = nil
            }
        }
        .disabled(!remote.canSetVolume)
        .accessibilityLabel("Гучність")
    }

    private func update(_ percent: Int) {
        if !editing { remote.setVolume(percent: percent); return }
        draft = percent
        guard .now >= nextPreview, percent != lastPreview else { return }
        remote.setVolume(percent: percent)
        lastPreview = percent
        nextPreview = .now.advanced(by: .milliseconds(250))
    }
}

/// Lens focus via learned vendor keys; hold to keep the motor running.
struct FocusStrip: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        let status = remote.status
        let ready = status.available("focusUp") || status.available("focusDown")
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Фокус").font(.headline)
                Spacer()
                if !ready {
                    Text(status.reason("focusUp") == "learn_required" ? "Навчіть кнопки в розділі «Проєктор»" : Reason.text(status.reason("focusUp") ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack(spacing: 10) {
                HoldKey(symbol: "minus.magnifyingglass", label: "Ближче", key: "focusDown")
                HoldKey(symbol: "scope", label: "Авто", key: "autoFocus")
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
    @State private var task: Task<Void, Never>?

    var body: some View {
        let available = remote.status.available(key)
        Label(label, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(task == nil ? Color.surfaceRaised : Color.accentColor.opacity(0.25), in: .rect(cornerRadius: 12))
            .opacity(available ? 1 : 0.45)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard task == nil else { return }
                    guard available else { remote.show(Reason.text(remote.status.reason(key) ?? "")); task = Task {}; return }
                    task = Task {
                        remote.key(key)
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled {
                            remote.key(key)
                            try? await Task.sleep(for: .milliseconds(180))
                        }
                    }
                }
                .onEnded { _ in task?.cancel(); task = nil })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Фокус: \(label)")
            .accessibilityAction { remote.key(key) }
    }
}

struct PowerMenu: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        Menu {
            Button { remote.key("standby") } label: { Label("Режим сну", systemImage: "moon") }
            Button { remote.key("wakeup") } label: { Label("Розбудити", systemImage: "sun.max") }
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
                    Text(remote.status.keyboard == "ready" ? "Текст з’явиться в полі на проєкторі."
                         : Reason.text(remote.status.keyboard))
                }
                Section {
                    Button("Надіслати в поле", action: sendText).disabled(text.isEmpty)
                    Button("Відкрити як посилання") { remote.send("open", ["destination": "url", "value": text]); dismiss() }
                        .disabled(!(text.hasPrefix("http://") || text.hasPrefix("https://")))
                }
                Section {
                    Button { remote.send("text", ["action": "delete", "text": ""]) } label: { Label("Стерти символ", systemImage: "delete.left") }
                    Button { remote.send("text", ["action": "enter", "text": ""]) } label: { Label("Enter", systemImage: "return") }
                    if remote.firmware {
                        ForEach(Lumina.keyboardCommands) { command in
                            Button(command.title) { remote.firmwareCommand(command) }
                        }
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
        remote.send("text", ["action": "text", "text": text])
        text = ""
    }
}
