import AppIntents
import Foundation

/// Play/pause for the Live Activity button and the iOS 18 Control.
///
/// LiveActivityIntent => the system launches the app in the background and
/// performs this in the APP process, where the Bluetooth link lives.
/// We await the actual delivery so the process stays alive long enough to
/// reconnect to the treadmill after a cold launch (intents get ~30 s).
///
/// Lock-screen behaviour, verified against Apple docs + compiled metadata:
/// `authenticationPolicy` is correctly recorded as alwaysAllowed, but WidgetKit
/// keeps Live Activity buttons inactive on a locked device regardless. Controls
/// honour the policy — that is the no-unlock surface.
struct ToggleWalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause the treadmill"
    static var description = IntentDescription("Starts, pauses or resumes the Walker treadmill.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var isDiscoverable: Bool = true
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // never executed here (LiveActivityIntent runs in the app process);
        // present only so the extension can reference the type
        return .result()
        #else
        await TreadmillManager.shared.performLockScreenToggle()
        return .result()
        #endif
    }
}
