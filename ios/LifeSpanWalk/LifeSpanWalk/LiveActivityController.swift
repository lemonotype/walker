import Foundation
import ActivityKit

final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<WalkActivityAttributes>?
    private var lastUpdate = Date.distantPast

    func start(state: WalkActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        activity = try? Activity.request(
            attributes: WalkActivityAttributes(),
            content: .init(state: state, staleDate: nil))
        lastUpdate = Date()
    }

    func update(state: WalkActivityAttributes.ContentState) {
        guard let activity else { return }
        lastUpdate = Date()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Data notifications arrive at 1Hz; the lock screen only needs a
    /// refresh every ~15s (the timer text ticks by itself).
    func updateThrottled(state: WalkActivityAttributes.ContentState) {
        guard Date().timeIntervalSince(lastUpdate) > 15 else { return }
        update(state: state)
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .after(.now + 5)) }
    }
}
