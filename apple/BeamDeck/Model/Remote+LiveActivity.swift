#if os(iOS)
import ActivityKit
import Foundation

/// Keeps one Live Activity alive while a projector is connected, so the remote sits on the Lock Screen
/// and in the Dynamic Island.
@MainActor
private enum LiveRemoteActivity {
    static var current: Activity<RemoteActivityAttributes>? = Activity<RemoteActivityAttributes>.activities.first
}

extension Remote {
    var liveRemoteEnabled: Bool { UserDefaults.standard.object(forKey: "liveRemote") as? Bool ?? true }

    /// Starts, updates or ends the Live Activity to match the connection and the user's setting.
    func refreshLiveRemote() {
        let wanted = liveRemoteEnabled && hasSavedProjector && !demo
        let state = RemoteActivityAttributes.ContentState(connected: connected)
        let content = ActivityContent(state: state, staleDate: nil)

        if !wanted {
            guard let activity = LiveRemoteActivity.current else { return }
            LiveRemoteActivity.current = nil
            Task { await activity.end(content, dismissalPolicy: .immediate) }
            return
        }
        if let activity = LiveRemoteActivity.current, activity.activityState == .active {
            Task { await activity.update(content) }
            return
        }
        guard connected, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        LiveRemoteActivity.current = try? Activity.request(
            attributes: RemoteActivityAttributes(projectorName: projectorName),
            content: content,
            pushType: nil
        )
    }

    /// A Lock Screen button can wake the app before Bluetooth has reconnected; wait briefly for the link.
    func pressFromBackground(_ key: String) async {
        for _ in 0..<40 where !connected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connected else { return }
        self.key(key)
    }
}
#endif
