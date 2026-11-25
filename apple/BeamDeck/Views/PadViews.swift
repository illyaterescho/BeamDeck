import SwiftUI

/// Mouse cursor on the projector: a multi-touch trackpad, or the phone itself as an air mouse.
struct TouchpadView: View {
    @EnvironmentObject private var remote: Remote
    @State private var last: CGSize = .zero
    @State private var lastScroll: CGFloat = 0
    @State private var lastHorizontalScroll: CGFloat = 0
    @AppStorage("pointerSpeed") private var speed = 2.4
    @AppStorage("pointerMode") private var mode = Mode.pad
    #if os(iOS)
    @State private var air = AirMouse()
    @State private var aiming: Date?
    @State private var dragging = false
    #endif

    enum Mode: String { case pad, air }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                #if os(iOS)
                Picker("Режим", selection: $mode) {
                    Text("Тачпад").tag(Mode.pad)
                    Text("Повітряна миша").tag(Mode.air)
                }
                .pickerStyle(.segmented)
                #endif
                if mode == .air {
                    airPad
                } else {
                    HStack(spacing: 10) {
                        pad
                        scrollStrip
                    }
                    horizontalScrollStrip
                }
                HStack(spacing: 18) {
                    RoundKey(symbol: "chevron.backward", label: "Назад", key: "back")
                    RoundKey(symbol: "house", label: "Додому", key: "home")
                    RoundKey(symbol: "circle.circle", label: "OK", key: "ok")
                    Button("Правий клік", systemImage: "cursorarrow.click.2", action: remote.rightClick)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                HStack {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: $speed, in: 1...5)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Швидкість курсора")
            }
            .padding(20)
            .navigationTitle("Тачпад")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { air.stop() }
            #endif
        }
    }

    /// Hold the button and point the phone; a short tap clicks.
    @ViewBuilder private var airPad: some View {
        #if os(iOS)
        RoundedRectangle(cornerRadius: 28)
            .fill(aiming == nil ? Color.surface : Color.accentColor.opacity(0.22))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: aiming == nil ? "iphone.radiowaves.left.and.right" : "scope")
                        .font(.system(size: 40, weight: .light))
                    Text(aiming == nil ? "Утримуйте й ведіть телефоном,\nщоб рухати курсор. Короткий дотик — клік."
                         : "Ведіть телефоном…")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(aiming == nil ? .secondary : .primary)
                .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: 28))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard aiming == nil else { return }
                    aiming = Date()
                    remote.haptic += 1
                    air.start(speed: speed) { remote.move(by: $0) }
                }
                .onEnded { _ in
                    air.stop()
                    if let start = aiming, Date().timeIntervalSince(start) < 0.25 { remote.click() }
                    aiming = nil
                })
            .overlay(alignment: .bottom) {
                if !air.available {
                    Text("Гіроскоп недоступний на цьому пристрої.").font(.caption).foregroundStyle(.red).padding()
                }
            }
            .accessibilityLabel("Повітряна миша")
            .accessibilityAction { remote.click() }
        #else
        EmptyView()
        #endif
    }

    private var horizontalScrollStrip: some View {
        Capsule()
            .fill(Color.surface)
            .frame(height: 34)
            .overlay { Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary) }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let delta = value.translation.width - lastHorizontalScroll
                    guard abs(delta) >= 14 else { return }
                    lastHorizontalScroll = value.translation.width
                    remote.horizontalScroll(Double(delta * 3))
                }
                .onEnded { _ in lastHorizontalScroll = 0 })
            .accessibilityLabel("Горизонтальна прокрутка")
    }

    /// Light acceleration: quick flicks travel further than slow, precise moves.
    private func accelerate(_ step: CGSize) -> CGSize {
        let velocity = hypot(step.width, step.height)
        let gain = speed * (1 + min(velocity, 24) / 16)
        return CGSize(width: step.width * gain, height: step.height * gain)
    }

    private var pad: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Color.surface)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw").font(.title2)
                    Text(padHint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            }
            #if os(iOS)
            .overlay {
                TrackpadSurface(
                    onMove: { remote.move(by: accelerate($0)) },
                    onScroll: { dx, dy in
                        if dy != 0 { remote.scroll(by: Double(dy * 6)) }
                        if dx != 0 { remote.horizontalScroll(Double(dx * 3)) }
                    },
                    onTap: { remote.click() },
                    onSecondaryTap: remote.rightClick,
                    onDragStart: { dragging = true; remote.pointerDown() },
                    onDragEnd: { dragging = false; remote.pointerUp() },
                    dragEnabled: true
                )
            }
            .overlay(alignment: .top) {
                if dragging {
                    Label("Перетягування", systemImage: "hand.point.up.left.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            #else
            .contentShape(.rect(cornerRadius: 28))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let step = CGSize(width: value.translation.width - last.width, height: value.translation.height - last.height)
                    last = value.translation
                    remote.move(by: accelerate(step))
                }
                .onEnded { _ in last = .zero })
            .simultaneousGesture(TapGesture().onEnded { remote.click() })
            #endif
            .accessibilityElement()
            .accessibilityLabel("Тачпад")
            .accessibilityAction { remote.click() }
    }

    private var padHint: String {
        #if os(iOS)
        "Один палець — курсор, дотик — клік.\nДва пальці — прокрутка, дотик двома — правий клік.\nУтримайте й ведіть — перетягування."
        #else
        "Ведіть, щоб рухати курсор. Клік — дотик."
        #endif
    }

    private var scrollStrip: some View {
        Capsule()
            .fill(Color.surface)
            .frame(width: 44)
            .overlay {
                VStack {
                    Image(systemName: "chevron.up")
                    Spacer()
                    Image(systemName: "arrow.up.and.down").font(.caption)
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .foregroundStyle(.tertiary)
                .padding(.vertical, 16)
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let delta = value.translation.height - lastScroll
                    guard abs(delta) > 18 else { return }
                    lastScroll = value.translation.height
                    remote.scroll(by: Double(delta * 6))
                }
                .onEnded { _ in lastScroll = 0 })
            .accessibilityLabel("Прокрутка")
    }
}
