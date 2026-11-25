import SwiftUI

struct BluetoothConnectionsView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var link: BeamLink
    @EnvironmentObject private var lumina: LuminaLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Вбудований приймач") {
                    if lumina.connected {
                        Label(lumina.connectedName ?? "Проєктор", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if remote.hasReceiverSession {
                            Button("Від’єднати Bluetooth") { remote.detachFirmware() }
                        } else {
                            Button("Від’єднати Bluetooth") { remote.disconnect(); dismiss() }
                        }
                    } else {
                        ForEach(lumina.nearby.sorted { $0.rssi > $1.rssi }) { device in
                            Button {
                                if remote.hasReceiverSession { remote.attachFirmware(device.id) }
                                else { remote.connectFirmware(device.id) }
                            } label: {
                                HStack {
                                    Label(device.name, systemImage: "dot.radiowaves.left.and.right")
                                    Spacer()
                                    if lumina.phase == .connecting && lumina.connectedName == device.name {
                                        ProgressView()
                                    } else {
                                        SignalBars(rssi: device.rssi)
                                    }
                                }
                            }
                        }
                        if case .failed(let problem) = lumina.phase {
                            Text(problem).font(.footnote).foregroundStyle(.red)
                        } else if lumina.nearby.isEmpty {
                            discovery
                        }
                    }
                }

                Section("BeamDeck Agent через Bluetooth") {
                    if link.phase == .ready {
                        Label(link.connectedName ?? "Проєктор", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(link.nearby.sorted { $0.rssi > $1.rssi }) { device in
                            Button {
                                dismiss()
                                remote.connectBeam(device.id)
                            } label: {
                                HStack {
                                    Label(device.name, systemImage: "videoprojector")
                                    Spacer()
                                    SignalBars(rssi: device.rssi)
                                }
                            }
                        }
                        if link.nearby.isEmpty { discovery }
                    }
                }
            }
            .navigationTitle("Bluetooth")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear { scan() }
        }
    }

    @ViewBuilder private var discovery: some View {
        if link.bluetoothReady {
            Label("Шукаємо проєктор поруч…", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        } else {
            Text("Увімкни Bluetooth і дозволь BeamDeck доступ до нього.")
                .foregroundStyle(.secondary)
            #if os(iOS)
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Налаштування BeamDeck", destination: settings)
            }
            #endif
        }
    }

    private func scan() {
        if link.phase != .ready { link.scan() }
        if !lumina.connected { lumina.scan() }
    }
}

#if os(iOS)
struct PhoneProjectionView: View {
    @EnvironmentObject private var remote: Remote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if #available(iOS 27.0, *) {
            PhoneProjectionControls(mirror: remote.phoneMirror)
        } else {
            NavigationStack {
                Form {
                    Section("AirPlay") {
                        AirPlayProjectionRow()
                    }
                }
                .navigationTitle("Екран iPhone")
                .toolbar { Button("Готово") { dismiss() } }
            }
        }
    }
}

@available(iOS 27.0, *)
private struct PhoneProjectionControls: View {
    @EnvironmentObject private var remote: Remote
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var mirror: PhoneMirror

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if mirror.phase == .sharing {
                        Label("Трансляція активна", systemImage: "record.circle")
                            .foregroundStyle(.red)
                        Button("Зупинити трансляцію", role: .destructive) { mirror.stop() }
                    } else if mirror.phase == .starting || mirror.phase == .choosing {
                        HStack {
                            ProgressView()
                            Text(mirror.phase == .choosing ? "Очікуємо вибору екрана…" : "Підключаємо проєктор…")
                        }
                        Button("Скасувати", role: .cancel) { mirror.stop() }
                    } else if let connection = remote.projectOverWiFi,
                              remote.status.receiver["screenMirror"] as? Bool == true {
                        Button("Почати трансляцію", systemImage: "iphone.radiowaves.left.and.right") {
                            mirror.choose(connection)
                        }
                    } else {
                        Text("Для трансляції з BeamDeck потрібен Agent 0.3.4 і з’єднання через Wi-Fi.")
                            .foregroundStyle(.secondary)
                    }
                    if let problem = mirror.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("BeamDeck через Wi-Fi")
                } footer: {
                    Text("iPhone попросить підтвердити спільний доступ до екрана. Зображення надходить на вибраний проєктор без мікрофона й звуку.")
                }

                if mirror.phase == .idle {
                    Section("AirPlay") { AirPlayProjectionRow() }
                }
            }
            .navigationTitle("Екран iPhone")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }.disabled(mirror.phase != .idle)
                }
            }
        }
        .interactiveDismissDisabled(mirror.phase != .idle)
    }
}

private struct AirPlayProjectionRow: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        if remote.firmware {
            Button("Відкрити AirPlay на проєкторі", systemImage: "airplay.video") {
                remote.firmwareCommand(.init("AirPlay", 4, 17))
            }
        }
        Text("У Центрі керування iPhone відкрий «Дублювання екрана» й вибери AirPlay-приймач проєктора.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
#endif
