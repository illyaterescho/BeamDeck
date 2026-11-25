import SwiftUI

@main
struct BeamDeckApp: App {
    @StateObject private var remote = Remote()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(remote)
                .environmentObject(remote.link)
                .environmentObject(remote.lumina)
                #if os(macOS)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 720, idealHeight: 820)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject private var remote: Remote
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if remote.showRemote { MainTabs() }
            else { ConnectView() }
        }
        .animation(.smooth, value: remote.showRemote)
        .task(id: scenePhase) {
            if scenePhase == .active { await remote.monitorWiFi() }
        }
        .overlay(alignment: .bottom) {
            if let notice = remote.notice {
                Text(notice)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { remote.notice = nil }
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: remote.haptic)
        // beamdeck://open?url=… and beamdeck://type?text=… — lets the Shortcuts share sheet hand content to the projector.
        .onOpenURL { url in
            guard url.scheme == "beamdeck",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
            let value = items.first { $0.name == "url" || $0.name == "text" }?.value ?? ""
            remote.deliver(value)
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        TabView {
            RemoteView().tabItem { Label("Пульт", systemImage: "av.remote") }
            TouchpadView().tabItem { Label("Тачпад", systemImage: "hand.point.up.left") }
            AppsView().tabItem { Label("Програми", systemImage: "square.grid.2x2") }
            #if os(iOS)
            ScreenView().tabItem { Label("Екран", systemImage: "tv") }
            #else
            if remote.hasReceiverSession || remote.demo {
                ScreenView().tabItem { Label("Екран", systemImage: "tv") }
            }
            #endif
            ProjectorView().tabItem { Label("Проєктор", systemImage: "videoprojector") }
        }
    }
}

extension Color {
    /// Grouped surfaces that follow the system palette on both platforms.
    static var surface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    static var surfaceRaised: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemBackground)
        #else
        Color.primary.opacity(0.11)
        #endif
    }
}
