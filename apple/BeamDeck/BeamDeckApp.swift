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
    @EnvironmentObject private var link: BeamLink
    @EnvironmentObject private var lumina: LuminaLink

    private var showRemote: Bool {
        switch link.phase {
        case .ready: true
        case .connecting, .securing: link.token != nil // brief reconnects keep the remote on screen
        default: false
        }
    }

    var body: some View {
        Group {
            if remote.firmware { MainTabs(firmwareOnly: true) }
            else if showRemote || remote.demo { MainTabs() }
            else { ConnectView() }
        }
        .animation(.smooth, value: showRemote)
        .animation(.smooth, value: remote.firmware)
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
    }
}

struct MainTabs: View {
    /// The firmware receiver gives no Wi-Fi, so app list and screen preview are hidden in that mode.
    var firmwareOnly = false

    var body: some View {
        TabView {
            RemoteView().tabItem { Label("Пульт", systemImage: "av.remote") }
            TouchpadView().tabItem { Label("Тачпад", systemImage: "hand.point.up.left") }
            if !firmwareOnly {
                AppsView().tabItem { Label("Програми", systemImage: "square.grid.2x2") }
                ScreenView().tabItem { Label("Екран", systemImage: "tv") }
            }
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
