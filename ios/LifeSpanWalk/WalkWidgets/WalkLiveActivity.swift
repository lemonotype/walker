import ActivityKit
import WidgetKit
import SwiftUI

struct WalkLiveActivity: Widget {
    private let lime = Color(red: 0.84, green: 1.0, blue: 0.0)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            // Lock screen banner — brutalist: black, mono, hard edges
            HStack(spacing: 16) {
                Button(intent: ToggleWalkIntent()) {
                    Image(systemName: context.state.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(context.state.running ? Color.white : lime))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    if context.state.running {
                        Text(timerInterval: context.state.startedAt...Date(
                            timeInterval: 8 * 3600, since: context.state.startedAt),
                             countsDown: false)
                            .font(.system(.title2, design: .monospaced).weight(.black))
                    } else {
                        Text(elapsedText(context.state.elapsedS))
                            .font(.system(.title2, design: .monospaced).weight(.black))
                    }
                    Text(String(format: "%.2f KM · %d STEPS",
                                context.state.distanceM / 1000, context.state.steps))
                        .font(.system(.footnote, design: .monospaced).weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.state.running ? "WALK" : "PAUSE")
                    .font(.system(.caption, design: .monospaced).weight(.black))
                    .foregroundStyle(context.state.running ? lime : .secondary)
                    .kerning(2)
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(lime)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Button(intent: ToggleWalkIntent()) {
                        Image(systemName: context.state.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(.black)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 11)
                                .fill(context.state.running ? Color.white : lime))
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(String(format: "%.2f KM", context.state.distanceM / 1000))
                        .font(.system(.title3, design: .monospaced).weight(.black))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.running {
                        Text(timerInterval: context.state.startedAt...Date(
                            timeInterval: 8 * 3600, since: context.state.startedAt),
                             countsDown: false)
                            .font(.system(.title3, design: .monospaced).weight(.black))
                            .frame(maxWidth: 64)
                    } else {
                        Text(elapsedText(context.state.elapsedS))
                            .font(.system(.title3, design: .monospaced).weight(.black))
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(lime)
            } compactTrailing: {
                if context.state.running {
                    Text(timerInterval: context.state.startedAt...Date(
                        timeInterval: 8 * 3600, since: context.state.startedAt),
                         countsDown: false)
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "pause.fill")
                }
            } minimal: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(lime)
            }
        }
    }

    private func elapsedText(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                  : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
