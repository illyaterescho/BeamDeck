import SwiftUI

/// Mouse cursor on the projector: a multi-touch trackpad, or the phone itself as an air mouse.
struct TouchpadView: View {
    @EnvironmentObject private var remote: Remote
    @State private var last: CGSize = .zero
    @State private var lastScroll: CGFloat = 0
    @State private var lastHorizontalScroll: CGFloat = 0
    @AppStorage("pointerSpeed") private var speed = 2.4
    @AppStorage("pointerMode") private var mode = Mode.pad
    #if os(iOS)
    @State private var air = AirMouse()
    @State private var aiming: Date?
    @State private var dragging = false
    #endif

    enum Mode: String { case pad, air }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let reason = remote.status.reason("pointer") {
                    Label(Reason.text(reason), systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(iOS)
                Picker("Режим", selection: $mode) {
                    Text("Тачпад").tag(Mode.pad)
                    Text("Повітряна миша").tag(Mode.air)
                }
                .pickerStyle(.segmented)
                #endif
                if mode == .air {
                    airPad
                } else {
                    HStack(spacing: 10) {
                        pad
                        scrollStrip
                    }
                    if remote.firmware { horizontalScrollStrip }
                }
                HStack(spacing: 18) {
                    RoundKey(symbol: "chevron.backward", label: "Назад", key: "back")
                    RoundKey(symbol: "house", label: "Додому", key: "home")
                    RoundKey(symbol: "circle.circle", label: "OK", key: "ok")
                    if remote.firmware {
                        Button("Правий клік", systemImage: "cursorarrow.click.2", action: remote.rightClick)
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                }
                HStack {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: $speed, in: 1...5)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Швидкість курсора")
            }
            .padding(20)
            .navigationTitle("Тачпад")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { air.stop() }
            #endif
        }
    }

    /// Hold the button and point the phone; a short tap clicks.
    @ViewBuilder private var airPad: some View {
        #if os(iOS)
        RoundedRectangle(cornerRadius: 28)
            .fill(aiming == nil ? Color.surface : Color.accentColor.opacity(0.22))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: aiming == nil ? "iphone.radiowaves.left.and.right" : "scope")
                        .font(.system(size: 40, weight: .light))
                    Text(aiming == nil ? "Утримуйте й ведіть телефоном,\nщоб рухати курсор. Короткий дотик — клік."
                         : "Ведіть телефоном…")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(aiming == nil ? .secondary : .primary)
                .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: 28))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard aiming == nil else { return }
                    aiming = Date()
                    remote.haptic += 1
                    air.start(speed: speed) { remote.move(by: $0) }
                }
                .onEnded { _ in
                    air.stop()
                    if let start = aiming, Date().timeIntervalSince(start) < 0.25 { remote.send("click") }
                    aiming = nil
                })
            .overlay(alignment: .bottom) {
                if !air.available {
                    Text("Гіроскоп недоступний на цьому пристрої.").font(.caption).foregroundStyle(.red).padding()
                }
            }
            .accessibilityLabel("Повітряна миша")
            .accessibilityAction { remote.send("click") }
        #else
        EmptyView()
        #endif
    }

    private var horizontalScrollStrip: some View {
        Capsule()
            .fill(Color.surface)
            .frame(height: 34)
            .overlay { Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary) }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let delta = value.translation.width - lastHorizontalScroll
                    guard abs(delta) >= 14 else { return }
                    lastHorizontalScroll = value.translation.width
                    remote.horizontalScroll(Double(delta * 3))
                }
                .onEnded { _ in lastHorizontalScroll = 0 })
            .accessibilityLabel("Горизонтальна прокрутка")
    }

    /// Light acceleration: quick flicks travel further than slow, precise moves.
    private func accelerate(_ step: CGSize) -> CGSize {
        let velocity = hypot(step.width, step.height)
        let gain = speed * (1 + min(velocity, 24) / 16)
        return CGSize(width: step.width * gain, height: step.height * gain)
    }

    private var pad: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Color.surface)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw").font(.title2)
                    Text(padHint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            }
            #if os(iOS)
            .overlay {
                TrackpadSurface(
                    onMove: { remote.move(by: accelerate($0)) },
                    onScroll: { dx, dy in
                        if dy != 0 { remote.scroll(by: Double(dy * 6)) }
                        if dx != 0 { remote.horizontalScroll(Double(dx * 3)) }
                    },
                    onTap: { remote.send("click") },
                    onSecondaryTap: remote.rightClick,
                    onDragStart: { dragging = true; remote.pointerDown() },
                    onDragEnd: { dragging = false; remote.pointerUp() },
                    dragEnabled: remote.canDrag
                )
            }
            .overlay(alignment: .top) {
                if dragging {
                    Label("Перетягування", systemImage: "hand.point.up.left.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            #else
            .contentShape(.rect(cornerRadius: 28))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let step = CGSize(width: value.translation.width - last.width, height: value.translation.height - last.height)
                    last = value.translation
                    remote.move(by: accelerate(step))
                }
                .onEnded { _ in last = .zero })
            .simultaneousGesture(TapGesture().onEnded { remote.send("click") })
            #endif
            .accessibilityElement()
            .accessibilityLabel("Тачпад")
            .accessibilityAction { remote.send("click") }
    }

    private var padHint: String {
        #if os(iOS)
        remote.canDrag
            ? "Один палець — курсор, дотик — клік.\nДва пальці — прокрутка, дотик двома — правий клік.\nУтримайте й ведіть — перетягування."
            : "Один палець — курсор, дотик — клік.\nДва пальці — прокрутка."
        #else
        "Ведіть, щоб рухати курсор. Клік — дотик."
        #endif
    }

    private var scrollStrip: some View {
        Capsule()
            .fill(Color.surface)
            .frame(width: 44)
            .overlay {
                VStack {
                    Image(systemName: "chevron.up")
                    Spacer()
                    Image(systemName: "arrow.up.and.down").font(.caption)
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .foregroundStyle(.tertiary)
                .padding(.vertical, 16)
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let delta = value.translation.height - lastScroll
                    guard abs(delta) > 18 else { return }
                    lastScroll = value.translation.height
                    remote.scroll(by: Double(delta * 6))
                }
                .onEnded { _ in lastScroll = 0 })
            .accessibilityLabel("Прокрутка")
    }
}

struct AppsView: View {
    @EnvironmentObject private var remote: Remote
    @State private var query = ""
    @AppStorage("favoriteApps") private var favoritesRaw = ""

    private var favorites: Set<String> { Set(favoritesRaw.split(separator: "\n").map(String.init)) }

    private var shown: [LaunchableApp] {
        let filtered = query.isEmpty ? remote.apps : remote.apps.filter { $0.label.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { favorites.contains($0.id) && !favorites.contains($1.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if remote.apps.isEmpty {
                    ContentUnavailableView("Список програм недоступний", systemImage: "square.grid.2x2")
                        .padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 18) {
                    ForEach(shown) { app in
                        Button { remote.send("launch", ["appId": app.id]) } label: { AppTile(app: app, favorite: favorites.contains(app.id)) }
                            .buttonStyle(PressStyle())
                            .contextMenu {
                                Button(favorites.contains(app.id) ? "Прибрати з обраних" : "До обраних",
                                       systemImage: favorites.contains(app.id) ? "star.slash" : "star") { toggle(app) }
                                if remote.receiverReady, !app.id.hasPrefix("lumina."), remote.canSetVolume {
                                    Menu("Відкрити з гучністю") {
                                        ForEach([25, 50, 75], id: \.self) { percent in
                                            Button("\(percent)%") {
                                                remote.send("scene", ["appId": app.id, "percent": percent])
                                            }
                                        }
                                    }
                                }
                            }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Програми")
            .searchable(text: $query, prompt: "Пошук")
            .refreshable { await remote.loadApps() }
            .task(id: [remote.receiverReady, remote.firmware]) { await remote.loadApps() }
        }
    }

    private func toggle(_ app: LaunchableApp) {
        var set = favorites
        if !set.insert(app.id).inserted { set.remove(app.id) }
        favoritesRaw = set.sorted().joined(separator: "\n")
    }
}

struct AppTile: View {
    let app: LaunchableApp
    let favorite: Bool

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.surface)
                .frame(width: 72, height: 72)
                .overlay {
                    Text(String(app.label.prefix(1)).uppercased())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).padding(6)
                    }
                }
            Text(app.label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
    }
}

/// Live picture of the projector over Wi-Fi; tapping the picture taps the projector.
struct ScreenView: View {
    @EnvironmentObject private var remote: Remote
    @State private var frame: Image?
    @State private var problem: String?
    #if os(iOS)
    @State private var showPhoneProjection = false
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let frame {
                    GeometryReader { proxy in
                        frame
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 14))
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .contentShape(.rect)
                            .gesture(SpatialTapGesture().onEnded { tap in tapped(tap.location, in: proxy.size) })
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        Label("Наживо", systemImage: "circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.red, in: .capsule)
                            .padding(10)
                    }
                    Text("Торкніться зображення, щоб натиснути в цьому місці на проєкторі.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ContentUnavailableView {
                        Label("Екран проєктора", systemImage: "tv")
                    } description: {
                        Text(problem ?? "Підключаємося через Wi-Fi…")
                    }
                }
                #if os(iOS)
                Button("Показати екран iPhone", systemImage: "iphone.radiowaves.left.and.right") {
                    showPhoneProjection = true
                }
                .buttonStyle(.borderedProminent)
                #endif
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Екран")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPhoneProjection) { PhoneProjectionView() }
            #endif
            .task(id: previewAddress) { await stream() }
        }
    }

    private var previewAddress: String? {
        #if os(iOS)
        if showPhoneProjection { return nil }
        #endif
        return remote.wifiReady ? remote.wifiAddress : nil
    }

    private func stream() async {
        guard let address = previewAddress, let token = remote.sessionToken else {
            frame = nil
            problem = "Під’єднайте проєктор і телефон до однієї Wi-Fi мережі."
            return
        }
        while !Task.isCancelled {
            do {
                let data = try await WiFi.screen(address, token: token)
                guard !Task.isCancelled else { return }
                if let image = PlatformImage(data: data) {
                    #if os(iOS)
                    frame = Image(uiImage: image)
                    #else
                    frame = Image(nsImage: image)
                    #endif
                    problem = nil
                }
                try? await Task.sleep(for: .milliseconds(350))
            } catch {
                guard !Task.isCancelled else { return }
                frame = nil
                problem = error.localizedDescription
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func tapped(_ point: CGPoint, in size: CGSize) {
        // The image is letterboxed in a 16:9 box; map the touch into the picture's own coordinates.
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        remote.send("tapAt", ["x": Double(x), "y": Double(y)])
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif
