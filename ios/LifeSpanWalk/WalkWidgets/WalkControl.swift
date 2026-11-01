import WidgetKit
import SwiftUI
import AppIntents

/// iOS 18 Control: place it in a Lock Screen bottom corner, Control Center,
/// or on the Action button. Unlike Live Activity buttons — which iOS keeps
/// inactive on a locked device by design — Controls perform without
/// unlocking when the intent's authenticationPolicy is .alwaysAllowed.
struct WalkControl: ControlWidget {
    static let kind = "com.lemonotype.lifespanwalk.playpause"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleWalkIntent()) {
                Label("Treadmill", systemImage: "figure.walk")
            } actionLabel: { _ in
                Label("Sending…", systemImage: "figure.walk.motion")
            }
        }
        .displayName("Walker play / pause")
        .description("Start, pause or resume the treadmill. Works from the Lock Screen without unlocking.")
    }
}
