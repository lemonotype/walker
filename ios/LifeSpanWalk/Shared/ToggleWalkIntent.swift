import AppIntents
import Foundation

/// Play/pause button on the Live Activity (lock screen). LiveActivityIntent
/// performs in the app's process, so it just posts a notification that
/// TreadmillManager (app target) observes.
///
/// NOTE: authenticationPolicy MUST be a stored property — the App Intents
/// metadata extractor can silently miss computed properties, which brings
/// back the Face ID prompt on the lock screen.
struct ToggleWalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause the treadmill"
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: Notification.Name("lifespan.toggleWalk"), object: nil)
        return .result()
    }
}
