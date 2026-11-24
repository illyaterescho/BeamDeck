import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var link: BeamLink
    @State private var pin = ""
    @State private var pairing = false
    @State private var pinError: String?
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
                        Text("Відкрийте BeamDeck на проєкторі й тримайте телефон поруч. Wi-Fi не потрібен.")
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
                }
            }
            .navigationTitle("BeamDeck")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { if link.phase == .idle { link.scan() } }
            .onChange(of: link.phase) { _, phase in
                if phase == .needsPin { pin = ""; pinFocused = true }
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
                    link.connect(projector.id)
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
                Text("Якщо проєктора немає в списку, перевірте рядок «Bluetooth» на його екрані.")
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
            Button("Вибрати інший проєктор", role: .cancel) { link.disconnect(); link.scan() }
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
