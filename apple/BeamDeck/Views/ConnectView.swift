import SwiftUI

/// Finds the projector's built-in receiver over Bluetooth. No code, nothing installed on the projector.
struct ConnectView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var lumina: LuminaLink

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "videoprojector")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(.tint)
                            .frame(height: 64)
                        Text("Під’єднайте проєктор")
                            .font(.title2.bold())
                        Text("Увімкніть проєктор і тримайте телефон поруч. Wi-Fi і програми на проєкторі не потрібні.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section {
                    if lumina.nearby.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Шукаємо поруч…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(lumina.nearby.sorted { $0.rssi > $1.rssi }) { projector in
                        Button {
                            remote.connect(projector.id)
                        } label: {
                            HStack {
                                Label(projector.name, systemImage: "videoprojector")
                                Spacer()
                                if lumina.phase == .connecting, lumina.connectedName == projector.name {
                                    ProgressView()
                                } else {
                                    SignalBars(rssi: projector.rssi)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Проєктори поруч")
                } footer: {
                    if case .failed(let message) = lumina.phase {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Проєктор з’являється як HTC_Projector. Якщо до нього під’єднаний інший телефон з Lumina Go, спершу від’єднайте його.")
                    }
                }
            }
            .navigationTitle("BeamDeck")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { lumina.scan() }
        }
    }
}

struct SignalBars: View {
    let rssi: Int

    var body: some View {
        let level = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + bar * 4))
            }
        }
        .accessibilityLabel("Сигнал \(level) з 3")
    }
}
