#if os(iOS)
import SwiftUI

/// Hold the microphone, speak Ukrainian, release: the phrase is parsed on the phone and sent to the projector.
struct VoiceView: View {
    @EnvironmentObject private var remote: Remote
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = VoiceControl()
    @State private var actions: [VoiceAction] = []
    @State private var heard = ""
    @State private var holding = false

    private let examples = [
        "вниз три рази і ок", "на головну", "гучність 30", "тихіше двічі", "пауза",
        "відкрий ютуб", "знайди мультики", "напиши Дюна", "фокус ближче", "автофокус",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                Text(voice.listening ? (voice.transcript.isEmpty ? "Слухаю…" : voice.transcript)
                     : heard.isEmpty ? "Утримуйте кнопку й говоріть" : "«\(heard)»")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(voice.listening || !heard.isEmpty ? .primary : .secondary)
                    .frame(minHeight: 60)
                    .animation(.snappy, value: voice.transcript)

                microphone

                if let problem = voice.problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if !actions.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            Label(action.summary, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline)
                } else if !heard.isEmpty {
                    Text("Команду не впізнано. Спробуйте коротше, наприклад «вниз» чи «гучніше».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
                examplesList
            }
            .padding(20)
            .navigationTitle("Голос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { voice.cancel(); dismiss() } } }
            .onDisappear { voice.cancel() }
        }
        .presentationDetents([.large])
    }

    private var microphone: some View {
        Circle()
            .fill(voice.listening ? Color.red : Color.accentColor)
            .frame(width: 120, height: 120)
            .overlay(Image(systemName: voice.listening ? "waveform" : "mic.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: voice.listening))
            .scaleEffect(holding ? 1.08 : 1)
            .animation(.snappy(duration: 0.2), value: holding)
            .shadow(color: (voice.listening ? Color.red : .accentColor).opacity(0.35), radius: holding ? 22 : 10)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    actions = []
                    heard = ""
                    remote.haptic += 1
                    Task { await voice.start() }
                }
                .onEnded { _ in
                    holding = false
                    Task {
                        let phrase = await voice.finish()
                        heard = phrase
                        actions = VoiceCommands.parse(phrase)
                        if !actions.isEmpty { await remote.perform(actions) }
                    }
                })
            .sensoryFeedback(.start, trigger: voice.listening)
            .accessibilityLabel("Утримуйте, щоб говорити")
            .accessibilityAddTraits(.isButton)
    }

    private var examplesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Можна сказати").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            FlowRow(items: examples)
            Text(voice.onDevice ? "Розпізнавання працює на iPhone, без інтернету."
                 : "Українська розпізнається сервісом Apple, потрібен інтернет.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrapping row of example chips.
private struct FlowRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.surface, in: .capsule)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
#endif
