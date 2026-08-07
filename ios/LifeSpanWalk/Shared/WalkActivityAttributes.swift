import ActivityKit
import Foundation

struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var running: Bool
        var startedAt: Date
        var distanceM: Double
        var elapsedS: Int
        var steps: Int
    }
}
