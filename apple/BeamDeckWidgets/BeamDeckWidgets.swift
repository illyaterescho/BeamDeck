import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BeamDeckWidgets: WidgetBundle {
    var body: some Widget {
        RemoteLiveActivity()
    }
}

/// Mini remote on the Lock Screen and in the Dynamic Island while a projector is connected.
struct RemoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "videoprojector")
                    Text(context.attributes.projectorName).font(.subheadline.weight(.semibold))
                    Spacer()
                    StatusDot(connected: context.state.connected)
                }
                RemoteButtons(size: 44)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.projectorName, systemImage: "videoprojector")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusDot(connected: context.state.connected)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RemoteButtons(size: 40)
                }
            } compactLeading: {
                Image(systemName: "videoprojector")
            } compactTrailing: {
                Image(systemName: context.state.connected ? "dot.radiowaves.left.and.right" : "exclamationmark")
                    .foregroundStyle(context.state.connected ? .green : .orange)
            } minimal: {
                Image(systemName: "videoprojector")
            }
        }
    }
}

private struct StatusDot: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(connected ? Color.green : .orange).frame(width: 7, height: 7)
            Text(connected ? "Bluetooth" : "Підключення…").font(.caption2)
        }
        .opacity(0.85)
    }
}

/// Back, Home, play/pause and volume: the keys people reach for without unlocking the phone.
private struct RemoteButtons: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            key("back", "chevron.backward", "Назад")
            key("home", "house.fill", "Додому")
            key("playPause", "playpause.fill", "Пауза")
            key("volumeDown", "speaker.minus.fill", "Тихіше")
            key("volumeUp", "speaker.plus.fill", "Гучніше")
        }
    }

    private func key(_ key: String, _ symbol: String, _ label: String) -> some View {
        Button(intent: LiveKeyIntent(key: key)) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: size)
                .background(.white.opacity(0.16), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
