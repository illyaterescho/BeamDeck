import CryptoKit
import Foundation
import Security

/// BLE wire format shared with the projector (android BleLink.kt, PROTOCOL.md).
enum Wire {
    static let service = "6B1E0001-5EAF-4C1A-9C1E-BEA3DECC0001"
    static let rx = "6B1E0002-5EAF-4C1A-9C1E-BEA3DECC0001"
    static let tx = "6B1E0003-5EAF-4C1A-9C1E-BEA3DECC0001"
    static let info = Data("BeamDeck BLE v1".utf8)

    /// Splits a frame into GATT values: `[flags][chunk]`, 0x80 marks the last one.
    static func fragments(_ frame: Data, chunk: Int) -> [Data] {
        let size = max(19, chunk - 1)
        var parts: [Data] = []
        var offset = 0
        repeat {
            let end = min(frame.count, offset + size)
            var part = Data([end == frame.count ? 0x80 : 0x00])
            part.append(frame.subdata(in: offset..<end))
            parts.append(part)
            offset = end
        } while offset < frame.count
        return parts
    }

    struct Session {
        let privateKey = P256.KeyAgreement.PrivateKey()
        var key: SymmetricKey?

        var hello: Data { Data([0x01]) + privateKey.publicKey.x963Representation }

        mutating func accept(serverHello frame: Data) throws {
            guard frame.count == 1 + 65 + 16, frame.first == 0x02 else { throw LinkError.protocolMismatch }
            let body = frame.dropFirst()
            let server = try P256.KeyAgreement.PublicKey(x963Representation: body.prefix(65))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: server)
            key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: body.suffix(16), sharedInfo: info, outputByteCount: 32)
        }

        func seal(_ json: [String: Any]) throws -> Data {
            guard let key else { throw LinkError.notConnected }
            let plain = try JSONSerialization.data(withJSONObject: json)
            guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw LinkError.protocolMismatch }
            return Data([0x03]) + combined
        }

        func open(_ frame: Data) throws -> [String: Any] {
            guard let key, frame.first == 0x03 else { throw LinkError.protocolMismatch }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: frame.dropFirst()), using: key)
            guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
                throw LinkError.protocolMismatch
            }
            return object
        }
    }
}

enum LinkError: LocalizedError, Equatable {
    case notConnected, timeout, protocolMismatch, bluetoothOff, remote(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Проєктор не під’єднано."
        case .timeout: "Проєктор не відповів вчасно."
        case .protocolMismatch: "Оновіть BeamDeck на проєкторі."
        case .bluetoothOff: "Увімкніть Bluetooth на цьому пристрої."
        case .remote(let code): Reason.text(code)
        }
    }
}

/// Human text for receiver reason codes.
enum Reason {
    static func text(_ code: String) -> String {
        switch code {
        case "bad_pin": "Код не збігається. Перевірте цифри на екрані проєктора."
        case "pin_expired": "Код застарів. Виберіть «Новий код» на проєкторі."
        case "rate_limited": "Забагато спроб. Зачекайте хвилину."
        case "unauthorized": "Потрібно підключитися заново."
        case "accessibility_required": "Увімкніть «BeamDeck · Навігація» у спеціальних можливостях проєктора."
        case "adb_required": "Увімкніть налагодження по мережі на проєкторі. Інструкція в розділі «Проєктор»."
        case "adb_authorizing": "Підтвердьте «Дозволити налагодження» на екрані проєктора."
        case "adb_lost", "adb_timeout": "Системні кнопки тимчасово недоступні. Спробуйте ще раз."
        case "learn_required": "Спершу навчіть цю кнопку з пульта проєктора."
        case "media_access_required": "Надайте BeamDeck доступ до сповіщень на проєкторі."
        case "no_media", "media_action_unavailable": "Зараз нічого не відтворюється."
        case "no_focus": "На екрані немає елемента у фокусі."
        case "fixed_volume": "Гучність на проєкторі фіксована."
        case "launch_blocked": "Увімкніть «BeamDeck · Навігація», щоб відкривати програми."
        case "keyboard_required": "Виберіть клавіатуру BeamDeck на проєкторі."
        case "field_required": "Відкрийте текстове поле на проєкторі."
        case "protected_field": "Це поле пароля, туди BeamDeck не вводить текст."
        case "invalid_url": "Посилання має починатися з https:// або http://."
        case "unsupported": "Цей проєктор не підтримує дію."
        case "rejected": "Проєктор відхилив команду."
        case "busy": "Проєктор зайнятий. Спробуйте ще раз."
        default: "Не вдалося виконати команду."
        }
    }
}

/// Session tokens live in the Keychain, one per projector.
enum TokenStore {
    private static let service = "ua.beamdeck.remote.token"

    static func token(for id: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for id: String) {
        forget(id)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: id, kSecValueData as String: Data(token.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func forget(_ id: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id]
        SecItemDelete(query as CFDictionary)
    }
}
