import Foundation

/// A projector found over Bluetooth.
struct NearbyProjector: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
}

enum LinkError: LocalizedError, Equatable {
    case notConnected, remote(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Проєктор не під’єднано. Відкрийте вкладку «Проєктор» і під’єднайтеся."
        case .remote(let code): Reason.text(code)
        }
    }
}

/// Human text for error codes.
enum Reason {
    static func text(_ code: String) -> String {
        switch code {
        case "busy": "Забагато команд підряд. Зачекайте мить."
        case "invalid_url": "Посилання має починатися з https:// або http://."
        case "unsupported": "Цей проєктор не підтримує дію."
        default: "Не вдалося виконати команду."
        }
    }
}
