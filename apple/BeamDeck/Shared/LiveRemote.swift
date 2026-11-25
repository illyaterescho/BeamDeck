#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// Lock Screen / Dynamic Island remote. Shared by the app and the widget extension.
struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var connected: Bool
    }

    var projectorName: String
}

/// The app installs the handler at launch. The system runs a LiveActivityIntent in the app's process,
/// so the button press reaches the app's existing Bluetooth link.
enum LiveRemoteBridge {
    @MainActor static var press: (@MainActor (String) async -> Void)?
}

/// One remote key, sent from a button on the Lock Screen or in the Dynamic Island.
struct LiveKeyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Кнопка пульта"
    static let isDiscoverable = false

    @Parameter(title: "Кнопка")
    var key: String

    init() { key = "" }
    init(key: String) { self.key = key }

    func perform() async throws -> some IntentResult {
        await Self.press(key)
        return .result()
    }

    @MainActor private static func press(_ key: String) async {
        await LiveRemoteBridge.press?(key)
    }
}
#endif
