import SwiftUI

@main
struct LifeSpanWalkApp: App {
    @StateObject private var treadmill = TreadmillManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(treadmill)
        }
    }
}
