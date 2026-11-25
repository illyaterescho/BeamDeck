import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var link: BeamLink
    @EnvironmentObject private var lumina: LuminaLink
    @State private var pin = ""
    @State private var pairing = false
    @State private var pinError: String?
    @State private var wifiAddress = ""
    @State private var wifiPin = ""
    @State private var wifiPairing = false
    @State private var wifiError: String?
    @FocusState private var pinFocused: Bool

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
                        Text("Виберіть проєктор поруч або введіть адресу з екрана BeamDeck на проєкторі.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                if link.phase == .needsPin {
                    pinSection
                } else {
                    nearbySection
                    firmwareSection
                }
                wifiSection
            }
            .navigationTitle("BeamDeck")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                link.scan()
                lumina.scan()
                if wifiAddress.isEmpty { wifiAddress = remote.wifiAddress ?? "" }
            }
            .onChange(of: link.phase) { _, phase in
                if phase == .needsPin { pin = ""; pinFocused = true }
            }
        }
    }

    /// The projector's own built-in receiver (Lumina-compatible): no code, no projector-side setup.
    @ViewBuilder private var firmwareSection: some View {
        if !lumina.nearby.isEmpty {
            Section {
                ForEach(lumina.nearby.sorted { $0.rssi > $1.rssi }) { projector in
                    Button {
                        remote.connectFirmware(projector.id)
                    } label: {
                        HStack {
                            Label(projector.name, systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if lumina.phase == .connecting && lumina.connectedName == projector.name {
                                ProgressView()
                            } else {
                                SignalBars(rssi: projector.rssi)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Вбудований приймач проєктора")
            } footer: {
                if case .failed(let message) = lumina.phase { Text(message).foregroundStyle(.red) }
                else { Text("Пряме керування через Bluetooth без PIN-коду.") }
            }
        }
    }

    @ViewBuilder private var nearbySection: some View {
        Section {
            if link.nearby.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(link.bluetoothReady ? "Шукаємо поруч…" : "Очікуємо Bluetooth…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(link.nearby.sorted { $0.rssi > $1.rssi }) { projector in
                Button {
                    remote.connectBeam(projector.id)
                } label: {
                    HStack {
                        Label(projector.name, systemImage: "videoprojector")
                        Spacer()
                        if busy(projector) { ProgressView() } else { SignalBars(rssi: projector.rssi) }
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Поруч")
        } footer: {
            if case .failed(let message) = link.phase {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Після введення коду пульт сам підхопить Wi-Fi, якщо ви в одній мережі.")
            }
        }
    }

    private func busy(_ projector: NearbyProjector) -> Bool {
        (link.phase == .connecting || link.phase == .securing) && link.connectedName == projector.name
    }

    @ViewBuilder private var pinSection: some View {
        Section {
            VStack(spacing: 16) {
                Text("Введіть код з екрана проєктора")
                    .font(.headline)
                PinField(pin: $pin)
                    .focused($pinFocused)
                    .onChange(of: pin) { _, value in
                        pinError = nil
                        if value.count == 6 { submit() }
                    }
                if pairing { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } header: {
            Text(link.connectedName ?? "Проєктор")
        } footer: {
            if let pinError { Text(pinError).foregroundStyle(.red) }
            else { Text("Код потрібен лише під час першого підключення цього телефона.") }
        }
        Section {
            Button("Вибрати інший проєктор", role: .cancel) { remote.disconnect() }
        }
    }

    private var wifiSection: some View {
        Section("Підключення через Wi-Fi") {
            TextField("IP-адреса з екрана BeamDeck", text: $wifiAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)
                #endif
            TextField("Код із 6 цифр", text: $wifiPin)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .onChange(of: wifiPin) { _, value in
                    wifiPin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                }
            Button(wifiPairing ? "Підключення…" : "Підключити") {
                wifiPairing = true
                wifiError = nil
                Task {
                    defer { wifiPairing = false }
                    do { try await remote.pairWiFi(address: wifiAddress, pin: wifiPin) }
                    catch is CancellationError { }
                    catch { wifiError = error.localizedDescription }
                }
            }
            .disabled(wifiPairing || wifiPin.count != 6 || wifiAddress.isEmpty)
            if let wifiError { Text(wifiError).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func submit() {
        pairing = true
        Task {
            defer { pairing = false }
            do {
                try await link.pair(pin: pin)
            } catch {
                pinError = error.localizedDescription
                pin = ""
            }
        }
    }
}

/// Six boxes backed by one hidden field, so iOS still offers the one-time-code keyboard.
struct PinField: View {
    @Binding var pin: String

    var body: some View {
        ZStack {
            TextField("", text: $pin)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .opacity(0.02)
                .onChange(of: pin) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { pin = digits }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = index < pin.count ? String(Array(pin)[index]) : ""
                    Text(digit)
                        .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
                        .frame(width: 42, height: 52)
                        .background(Color.surfaceRaised, in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(index == pin.count ? Color.accentColor : .clear, lineWidth: 2)
                        }
                    if index == 2 { Spacer().frame(width: 6) }
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement()
        .accessibilityLabel("Код підключення")
        .accessibilityValue(pin)
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
