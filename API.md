# BeamDeck LAN API v1

Відкрийте адресу з екрана Agent. Production Remote і API мають один origin, наприклад `http://192.168.1.24:8765`. Сервер прив’язується до цієї адреси, перевіряє `Host` і приймає клієнтів з тієї самої приватної IPv4-підмережі. Браузерний `Origin` має збігатися з адресою Agent. Вебпульт використовує запити лише до джерела Agent.

## Pairing

`POST /api/v1/pair` приймає JSON `{"pin":"123456"}`. Потрібен актуальний шестизначний PIN з екрана Agent. Успішна відповідь — `{"paired":true}` та cookie `BeamDeckSession` із `HttpOnly`, `SameSite=Strict` і `Path=/api`. Сервер зберігає хеш токена. PIN діє 10 хвилин. Pairing обмежено п’ятьма спробами на IP і 30 загалом за хвилину.

Усі POST-запити потребують `Content-Type: application/json`, заголовка `X-BeamDeck-Request: 1` і JSON-об’єкта до 8192 байтів. Парний cookie потрібен для решти endpoint. Agent не вимагає заголовка `Origin` від локального CLI для звичайних HTTP-запитів. WebSocket вимагає origin та cookie. Загальний ліміт API — 70 запитів на IP та 340 на сервер за 10 секунд.

```sh
agent=http://192.168.1.24:8765
jar="$(mktemp)"
read -r pin
curl --fail-with-body -c "$jar" \
  -H 'Content-Type: application/json' -H 'X-BeamDeck-Request: 1' \
  --data "{\"pin\":\"$pin\"}" "$agent/api/v1/pair"
curl --fail-with-body -b "$jar" "$agent/api/v1/status"
curl --fail-with-body -b "$jar" -c "$jar" \
  -H 'Content-Type: application/json' -H 'X-BeamDeck-Request: 1' \
  --data '{}' "$agent/api/v1/logout"
rm -f "$jar"
```

## Запити

| Метод і шлях від `/api/v1` | Тіло | Відповідь |
| --- | --- | --- |
| `GET /status` | — | `device`, `volume`, `media`, `sleep`, `capabilities` |
| `GET /capabilities` | — | Об’єкт capability за ключем дії |
| `GET /apps` | — | `{"apps":[{"id":"package/.MainActivity","label":"Назва"}]}` |
| `POST /command` | `{"command":"volumeUp"}` | Результат дії |
| `POST /volume` | `{"level":7}` | Рівень Android, ціле число у `volume.min..volume.max` |
| `POST /launch` | `{"appId":"package/.MainActivity"}` | Запит на відкриття вибраного застосунку |
| `POST /scene` | `{"appId":"package/.MainActivity","percent":30}` | Установлений рівень і запит на запуск плеєра |
| `POST /sleep` | `{"minutes":30}` | Таймер від 1 до 180 хвилин, 0 скасовує |
| `POST /logout` | `{}` | `{"paired":false}` та відкликання cookie |
| `WS /live` | — | Статус у JSON приблизно кожні 1,5 с. Потік тільки для читання, до чотирьох з’єднань. |

`command` підтримує `volumeUp`, `volumeDown`, `mute`, `playPause`, `previous`, `next`, `back`, `home`, `up`, `down`, `left`, `right`, `ok`. Для запуску надсилайте фактичний `id` з `GET /apps`.

Кожна capability має форму `{"available":true}` або `{"available":false,"reason":"accessibility_required"}`. Ключі охоплюють назви команд, `volume`, `launch` і `sleep`. Статус відтворення `media.playing` і `media.app` може бути `null`. У `sleep` є `remainingMs` та `outcome` зі значенням `idle`, `scheduled`, `submitted`, `completed`, `partial` або `failed`. `submitted` для таймера означає вимкнений звук і надісланий запит паузи.

## Результати дії

- `{"outcome":"applied","code":"ok"}` означає, що Agent підтвердив дію через Android API або зареєстрував таймер.
- `{"outcome":"submitted","code":"media_submitted"}` означає, що MediaController прийняв медіаподію для доставки. Перевірте новий стан через `status`.
- `{"outcome":"submitted","code":"launch_submitted"}` означає, що Android прийняв запит на відкриття. Для Movie Night Agent до цього підтвердив гучність.

Помилки мають форму `{"error":{"code":"rejected"}}`.

| HTTP | Коди |
| --- | --- |
| 400 або 408 | `bad_request` |
| 401 | `bad_pin`, `unauthorized` |
| 403 | `forbidden` |
| 404 | `not_found` |
| 409 | `unsupported`, `accessibility_required`, `media_access_required`, `no_media`, `media_action_unavailable`, `fixed_volume`, `launch_blocked`, `rejected`, `partial_scene` |
| 410 | `pin_expired` |
| 429 | `rate_limited` |
| 500 | `internal_error` |

Після помилки з’єднання пульт повторює читання статусу. Дія з втраченою відповіддю могла вже дійти до Android, тому клієнт не повторює POST автоматично.

## Розширення 0.2

`GET /status` повертає додаткові поля `geometry`, `projector`, `cinema` і `player`. Геометрія має форму `{"mode":"manual","corners":[[0,0],[1,0],[1,1],[0,1]]}`. Кути йдуть за годинниковою стрілкою з верхнього лівого. Координати лежать у діапазоні [0,1]. Значення `auto` позначає збережений результат аналізу фото.

| Метод і шлях від `/api/v1` | Тіло або результат |
| --- | --- |
| `POST /geometry` | Об’єкт геометрії. Перевіряє й зберігає його. |
| `WS /geometry/live` | Повідомлення з геометрією, цілим `id` і `commit: boolean`. Підтвердження запису `{"id":1,"accepted":true}` або відповідь з `accepted:false` та `code`. |
| `POST /input` | `{"action":"text","text":"https://example.com/"}`. Дії `delete` й `enter` потребують порожнього тексту. |
| `POST /cinema/open` | `{"destination":"grid","value":""}`. Також доступні `player`, `settings`, `url`. Для `url` значення — повна HTTP/HTTPS адреса. |
| `POST /cinema/playback` | `{}`. Перемикає відтворення локального файлу в активному BeamDeck Player. |
| `POST /cinema/settings` | `{"settings":…}` із типізованими параметрами `cinema` зі статусу. |
| `GET /cinema/diagnostics` | Стан доступності, видимість пакета виробника та перелік видимих експортованих активностей кандидата та їхні задекларовані дозволи. |

WebSocket приймає лише текстові повідомлення до 1 КБ і працює з парним cookie й точним `Origin`. Проміжний кадр дає перегляд у плеєрі та сітці. Підтверджений `commit` записує профіль Agent. Якщо клієнт від’єднався до підтвердження, Agent повертає останню збережену геометрію. Звичайний POST до `/geometry` слугує резервним шляхом.

HTTP JSON обмежено 8192 байтами. Введення в поле обмежено 1500 символами й 4096 байтами UTF-8. `input_submitted` означає, що InputConnection прийняв запит. `keyboard_required`, `field_required` і `protected_field` пояснюють недоступність введення. `invalid_geometry` та `invalid_url` означають некоректні дані. `editor_busy` означає, що інший клієнт редагує геометрію. `video_required` означає, що у власному плеєрі ще немає відкритого відео.


## Розширення 0.2.2

`GET /status` і `GET /capabilities` включають можливості сумісного штатного приймача проєктора. `status.projector.navigation` і `status.projector.focus` можуть мати значення `lumina`. `POST /command` підтримує `focusUp`, `focusDown` і `autoFocus` лише за наявності відповідних штатних команд. Навігація та відносні команди гучності використовують штатний приймач, якщо він їх підтримує. `lumina_submitted` означає підтвердження приймачем, `lumina_unavailable` означає збій зв’язку з приймачем. BeamDeck виконує фіксований перелік команд.

`POST /volume` повертає поле `volume` з фактичним рівнем Android і запитує показ системної панелі. Відповідь команд гучності також містить підтверджений стан, коли Agent може прочитати його з Android.
