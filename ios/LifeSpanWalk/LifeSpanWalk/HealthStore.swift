import Foundation
import HealthKit

final class HealthStore {
    static let shared = HealthStore()
    private let store = HKHealthStore()

    func requestAuth() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.stepCount),
        ]
        store.requestAuthorization(toShare: types, read: []) { _, _ in }
    }

    func saveWorkout(start: Date, end: Date, distanceM: Double, kcal: Double, steps: Int) {
        guard HKHealthStore.isHealthDataAvailable(), end > start,
              end.timeIntervalSince(start) > 30 else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        builder.beginCollection(withStart: start) { ok, _ in
            guard ok else { return }
            var samples: [HKSample] = []
            if distanceM > 1 {
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.distanceWalkingRunning),
                    quantity: HKQuantity(unit: .meter(), doubleValue: distanceM),
                    start: start, end: end))
            }
            if kcal > 1 {
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                    start: start, end: end))
            }
            if steps > 0 {
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.stepCount),
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(steps)),
                    start: start, end: end))
            }
            let finish = {
                builder.endCollection(withEnd: end) { _, _ in
                    builder.finishWorkout { _, _ in }
                }
            }
            if samples.isEmpty { finish() } else { builder.add(samples) { _, _ in finish() } }
        }
    }
}
