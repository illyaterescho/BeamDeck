import SwiftUI

/// Mouse cursor on the projector: drag to move, tap to click, edge strip to scroll.
struct TouchpadView: View {
    @EnvironmentObject private var remote: Remote
    @State private var last: CGSize = .zero
    @State private var lastScroll: CGFloat = 0
    @AppStorage("pointerSpeed") private var speed = 2.4

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let reason = remote.status.reason("pointer") {
                    Label(Reason.text(reason), systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    pad
                    scrollStrip
                }
                HStack(spacing: 18) {
                    RoundKey(symbol: "chevron.backward", label: "Назад", key: "back")
                    RoundKey(symbol: "house", label: "Додому", key: "home")
                    RoundKey(symbol: "circle.circle", label: "OK", key: "ok")
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
            #endif
        }
    }

    private var pad: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Color.surface)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw").font(.title2)
                    Text("Ведіть пальцем, щоб рухати курсор.\nТоркніться, щоб натиснути.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: 28))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let step = CGSize(width: value.translation.width - last.width, height: value.translation.height - last.height)
                    last = value.translation
                    // Light acceleration: quick flicks travel further than slow, precise moves.
                    let velocity = hypot(step.width, step.height)
                    let gain = speed * (1 + min(velocity, 24) / 16)
                    remote.move(by: CGSize(width: step.width * gain, height: step.height * gain))
                }
                .onEnded { _ in last = .zero })
            .simultaneousGesture(TapGesture().onEnded { remote.send("click") })
            .accessibilityElement()
            .accessibilityLabel("Тачпад")
            .accessibilityAction { remote.send("click") }
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
                    remote.send("scroll", ["dx": 0, "dy": Double(delta * 6)])
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
                    ContentUnavailableView("Програми завантажуються", systemImage: "square.grid.2x2",
                                           description: Text("Список береться з проєктора."))
                        .padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 18) {
                    ForEach(shown) { app in
                        Button { remote.send("launch", ["appId": app.id]) } label: { AppTile(app: app, favorite: favorites.contains(app.id)) }
                            .buttonStyle(PressStyle())
                            .contextMenu {
                                Button(favorites.contains(app.id) ? "Прибрати з обраних" : "До обраних",
                                       systemImage: favorites.contains(app.id) ? "star.slash" : "star") { toggle(app) }
                            }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Програми")
            .searchable(text: $query, prompt: "Пошук")
            .refreshable { await remote.loadApps() }
            .task { if remote.apps.isEmpty { await remote.loadApps() } }
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
    @EnvironmentObject private var link: BeamLink
    @State private var frame: Image?
    @State private var problem: String?

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
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Екран")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: remote.status.lan) { await stream() }
        }
    }

    private func stream() async {
        while !Task.isCancelled {
            do {
                let data = try await WiFi.screen(remote.status.lan, token: link.token)
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
                frame = nil
                problem = remote.status.lan == nil
                    ? "Під’єднайте проєктор і телефон до однієї Wi-Fi мережі."
                    : error.localizedDescription
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
