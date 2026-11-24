# BeamDeck BLE protocol v1

Телефон напряму під’єднується до приймача на проєкторі, як Lumina Go. Wi-Fi для керування не потрібен.

## GATT

| | UUID | Властивості |
| --- | --- | --- |
| Сервіс | `6b1e0001-5eaf-4c1a-9c1e-bea3decc0001` | рекламується проєктором |
| RX (телефон → проєктор) | `6b1e0002-…-bea3decc0001` | write, write without response |
| TX (проєктор → телефон) | `6b1e0003-…-bea3decc0001` | notify |

Кожне значення GATT має вигляд `[flags][chunk]`. Біт `0x80` у `flags` позначає останній шматок кадру. Розмір шматка дорівнює MTU − 4 на проєкторі та `maximumWriteValueLength(.withoutResponse)` − 1 на телефоні.

## Кадри

1. `0x01 ‖ client P-256 public key (65 байтів X9.63)` надсилає телефон.
2. `0x02 ‖ server public key (65) ‖ salt (16)` відповідає проєктор.
3. Ключ сеансу: `HKDF-SHA256(ECDH secret, salt, "BeamDeck BLE v1", 32)`.
4. `0x03 ‖ nonce (12) ‖ AES-256-GCM ciphertext ‖ tag (16)`: усі подальші повідомлення в JSON.

Сумісність Kotlin і CryptoKit перевіряє `android/app/src/test/.../BleCryptoTest.kt` на векторі з `apple/Tools/ble-vector.swift`.

## Повідомлення

Запит: `{"id": 7, "op": "key", "key": "up"}`. Відповідь: `{"id": 7, "ok": true, …}` або `{"id": 7, "ok": false, "error": "adb_required"}`.
Проєктор сам надсилає `{"op": "status", "status": {…}}` після кожної зміни стану.

| op | Поля | Що робить |
| --- | --- | --- |
| `pair` | `pin` | Перше підключення за кодом з екрана. Повертає `token`. |
| `auth` | `token` | Повторне підключення без коду. |
| `status` | — | Повний стан (той самий, що `GET /api/v1/status`). |
| `key` | `key`, `long?` | `up down left right ok back home recents menu settings power standby wakeup input playPause next previous volumeUp volumeDown mute focusUp focusDown autoFocus keystone custom1 custom2` |
| `volume` | `level` | Абсолютна гучність Android. |
| `pointer` | `dx`, `dy` | Рух курсора в пікселях проєктора. |
| `click` / `scroll` / `tapAt` | — / `dx dy` / `x y` (0…1) | Натискання й прокрутка. |
| `text` | `action`, `text` | Введення в поле через клавіатуру BeamDeck. |
| `apps`, `launch`, `scene`, `sleep`, `open` | як у HTTP API | |
| `learn` / `forget` / `keymap` | `key` | Навчання кнопок фізичного пульта. |
| `adb` | — | Повторна перевірка loopback ADB. |

Той самий набір `op` доступний через Wi-Fi: `POST /api/v1/rpc` з тілом `{"op": "...", ...}` і cookie сеансу. Токен з BLE-сопряження чинний і для Wi-Fi.
