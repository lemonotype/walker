import Foundation
import CoreBluetooth
import Combine
import UserNotifications

struct SessionRecord: Codable {
    var date: Date
    var seconds: Int
    var meters: Double
    var steps: Int
    var kcal: Double
}

struct PeriodStats {
    var seconds = 0
    var meters = 0.0
    var steps = 0
}

/// Owns the BLE link to the ESP32 (FTMS treadmill service), the session
/// state (ramp engine, accumulated distance/steps across pauses), calorie
/// estimation and the hooks into HealthKit + the Live Activity.
final class TreadmillManager: NSObject, ObservableObject {
    static let shared = TreadmillManager()

    // MARK: - published state
    @Published var connected = false
    @Published var speedKmh: Double = 0        // actual belt speed
    @Published var targetKmh: Double = 0       // commanded speed
    @Published var distanceM: Double = 0       // accumulated across pauses
    @Published var elapsedS: Int = 0
    @Published var steps: Int = 0
    @Published var kcal: Double = 0
    @Published var sessionActive = false
    @Published var paused = false
    @Published var ramping = false
    @Published var history: [SessionRecord] = []
    @Published var maintenanceDue = false

    // MARK: - settings (UserDefaults, set by the UI via @AppStorage)
    private var defaults: UserDefaults { .standard }
    var startEndSpeed: Double { let v = defaults.double(forKey: "startEndSpeed"); return v > 0 ? v : 2.0 }
    var goalSpeed: Double { let v = defaults.double(forKey: "goalSpeed"); return v > 0 ? v : 4.0 }
    var rampMinutes: Double { let v = defaults.double(forKey: "rampMinutes"); return v > 0 ? v : 5.0 }
    var weightKg: Double { let v = defaults.double(forKey: "weightKg"); return v > 0 ? v : 70.0 }

    static let minKmh = 0.8
    static let maxKmh = 6.4

    // MARK: - BLE plumbing
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cpChar: CBCharacteristic?
    private let ftmsServiceUUID = CBUUID(string: "1826")
    private let dataUUID = CBUUID(string: "2ACD")
    private let cpUUID = CBUUID(string: "2AD9")
    private let statusUUID = CBUUID(string: "2ADA")
    private let stepsServiceUUID = CBUUID(string: "7C9A0001-3D3A-4E7B-8A10-25C1D9E0F2A4")
    private let stepsUUID = CBUUID(string: "7C9A0002-3D3A-4E7B-8A10-25C1D9E0F2A4")

    // MARK: - session internals
    private var rampTimer: Timer?
    private var sessionStart = Date()
    private var lastKcalUpdate = Date()
    // Firmware counters reset on belt starts AND on ESP32 reboots, and can
    // reappear with stale values after reconnects. We therefore accumulate
    // PLAUSIBLE DELTAS only (per ~1s notification), never absolute values:
    // impossible jumps are treated as artifacts and merely resync the
    // reference. Nothing accumulates while paused.
    private var lastFirmDist = -1.0
    private var lastFirmSteps = -1
    private var lastFirmElapsed = -1

    override private init() {
        super.init()
        if let d = defaults.data(forKey: "sessionHistory"),
           let h = try? JSONDecoder().decode([SessionRecord].self, from: d) {
            history = h
        }
        checkMaintenance()
        central = CBCentralManager(delegate: self, queue: .main)
        NotificationCenter.default.addObserver(
            forName: Notification.Name("lifespan.toggleWalk"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.togglePlayPause()
        }
    }

    // MARK: - control point commands
    private func cp(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = cpChar else { return }
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: c, type: type)
    }
    private func sendRequestControl() { cp([0x00]) }
    private func sendStart() { cp([0x07]) }
    private func sendStop() { cp([0x08, 0x01]) }
    private func sendSpeed(_ kmh: Double) {
        let clamped = min(Self.maxKmh, max(Self.minKmh, kmh))
        let v = UInt16((clamped * 100).rounded())
        cp([0x02, UInt8(v & 0xFF), UInt8(v >> 8)])
        targetKmh = clamped
    }

    // MARK: - session control
    func startSession() {
        guard connected, !sessionActive else { return }
        sessionActive = true
        paused = false
        sessionStart = Date()
        kcal = 0
        lastFirmDist = -1; distanceM = 0
        lastFirmSteps = -1; steps = 0
        lastFirmElapsed = -1; elapsedS = 0
        lastKcalUpdate = Date()
        goalRampStarted = false
        HealthStore.shared.requestAuth()
        sendStart()
        sendSpeed(startEndSpeed)
        startRamp(to: goalSpeed)
        LiveActivityController.shared.start(state: activityState())
    }

    /// "End": stop immediately (the MCB decelerates the belt itself) and
    /// save the workout to Apple Health.
    func endSession() {
        guard sessionActive else { return }
        finishSession()
    }

    private func finishSession() {
        rampTimer?.invalidate()
        pauseAutoEndTimer?.invalidate()
        ramping = false
        sendStop()
        sessionActive = false
        paused = false
        LiveActivityController.shared.end()
        recordSession()
        HealthStore.shared.saveWorkout(
            start: sessionStart, end: Date(),
            distanceM: distanceM, kcal: kcal, steps: steps)
    }

    private var lastToggle = Date.distantPast
    private var pendingToggleAt = Date.distantPast
    private var pauseAutoEndTimer: Timer?

    // MARK: - session history / period stats

    func stats(since: Date? = nil, until: Date? = nil) -> PeriodStats {
        var s = PeriodStats()
        for r in history {
            if let since, r.date < since { continue }
            if let until, r.date >= until { continue }
            s.seconds += r.seconds
            s.meters += r.meters
            s.steps += r.steps
        }
        return s
    }

    private func recordSession() {
        guard elapsedS > 30 else { return }
        history.append(SessionRecord(
            date: Date(), seconds: elapsedS, meters: distanceM,
            steps: steps, kcal: kcal))
        if let d = try? JSONEncoder().encode(history) {
            defaults.set(d, forKey: "sessionHistory")
        }
        checkMaintenance()
    }

    // MARK: - maintenance reminder (every 3 months OR 30 usage-hours)

    private func checkMaintenance() {
        var last = defaults.double(forKey: "maintLastReset")
        if last == 0 {  // first run: start the cycle now
            last = Date().timeIntervalSince1970
            defaults.set(last, forKey: "maintLastReset")
            defaults.set(stats().seconds, forKey: "maintBaselineS")
        }
        let baseline = defaults.integer(forKey: "maintBaselineS")
        let ageDays = (Date().timeIntervalSince1970 - last) / 86400
        let usedHours = Double(stats().seconds - baseline) / 3600
        let due = ageDays >= 90 || usedHours >= 30
        if due && !maintenanceDue { notifyMaintenanceOnce() }
        maintenanceDue = due
    }

    func dismissMaintenance() {
        defaults.set(Date().timeIntervalSince1970, forKey: "maintLastReset")
        defaults.set(stats().seconds, forKey: "maintBaselineS")
        defaults.set(false, forKey: "maintNotified")
        maintenanceDue = false
    }

    /// one system notification per cycle; the homepage banner persists
    private func notifyMaintenanceOnce() {
        guard !defaults.bool(forKey: "maintNotified") else { return }
        defaults.set(true, forKey: "maintNotified")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = "WALKER"
            c.body = "Maintenance due: lube belt and hoover motor (every 3 months / 30 hours of use)."
            center.add(UNNotificationRequest(
                identifier: "walker.maintenance", content: c, trigger: nil))
        }
    }

    // MARK: - session goal (time OR km OR steps)

    private var goalRampStarted = false

    private func checkGoal() {
        let type = defaults.string(forKey: "goalType") ?? "none"
        guard type != "none" else { return }
        var remainingMin: Double
        switch type {
        case "time":
            let g = defaults.double(forKey: "goalTimeMin")
            guard g > 0 else { return }
            remainingMin = (g * 60 - Double(elapsedS)) / 60
        case "km":
            let g = defaults.double(forKey: "goalKm")
            guard g > 0 else { return }
            let mps = max(speedKmh / 3.6, 0.15)
            remainingMin = (g * 1000 - distanceM) / mps / 60
        case "steps":
            let g = defaults.double(forKey: "goalSteps")
            guard g > 0 else { return }
            // average cadence so far; sane fallback in the first 2 minutes
            let rate = elapsedS > 120 ? Double(steps) / (Double(elapsedS) / 60) : 100
            remainingMin = (g - Double(steps)) / max(rate, 30)
        default:
            return
        }
        if remainingMin <= 0 {
            finishSession()  // goal reached: end + sync to Health
        } else if remainingMin <= 2, !goalRampStarted {
            // glide down to the start/end speed, arriving as the goal lands
            goalRampStarted = true
            startRamp(to: startEndSpeed, rampSeconds: max(remainingMin * 60 - 10, 30))
        }
    }

    /// A session left paused for an hour ends itself and syncs to Health.
    private func schedulePauseAutoEnd() {
        pauseAutoEndTimer?.invalidate()
        pauseAutoEndTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            guard let self, self.sessionActive, self.paused else { return }
            self.finishSession()
        }
    }

    func togglePlayPause() {
        // lock-screen intents can double-fire or trigger from accidental
        // grazes; a toggle within 1.5s of the previous one is not a human
        guard Date().timeIntervalSince(lastToggle) > 1.5 else { return }
        lastToggle = Date()
        guard sessionActive else {
            if connected {
                startSession()
            } else {
                // app was relaunched by the lock-screen intent: act as soon
                // as the treadmill link is back (see parseTreadmillData)
                pendingToggleAt = Date()
            }
            return
        }
        if paused {
            paused = false
            pauseAutoEndTimer?.invalidate()
            sendStart()
            // gentle resume: come back at the start/end speed, then a quick
            // ~15s ramp to wherever we were — not the full session ramp
            let resumeTarget = targetKmh > 0 ? targetKmh : startEndSpeed
            if resumeTarget <= startEndSpeed + 0.05 {
                sendSpeed(resumeTarget)
            } else {
                sendSpeed(startEndSpeed)
                startRamp(to: resumeTarget, rampSeconds: 15)
            }
        } else {
            paused = true
            rampTimer?.invalidate()
            ramping = false
            sendStop()
            schedulePauseAutoEnd()
        }
        LiveActivityController.shared.update(state: activityState())
    }

    func nudge(_ delta: Double) {
        guard sessionActive, !paused else { return }
        rampTimer?.invalidate()
        ramping = false
        sendSpeed(targetKmh + delta)
    }

    // MARK: - ramp engine: constant small increments every 5s
    private func startRamp(to goal: Double, rampSeconds: Double? = nil,
                           completion: (() -> Void)? = nil) {
        rampTimer?.invalidate()
        let seconds = rampSeconds ?? (rampMinutes * 60)
        // long session ramps step every 5s; short ramps (resume) subdivide
        // into ~8 smaller steps so they feel smooth
        let interval = min(5.0, max(1.5, seconds / 8))
        let start = targetKmh
        guard abs(goal - start) > 0.01, seconds > interval else {
            sendSpeed(goal)
            completion?()
            return
        }
        let increment = (goal - start) / (seconds / interval)
        ramping = true
        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self, self.sessionActive, !self.paused else {
                t.invalidate(); return
            }
            var next = self.targetKmh + increment
            let reached = (increment > 0 && next >= goal) || (increment < 0 && next <= goal)
            if reached { next = goal }
            self.sendSpeed((next * 100).rounded() / 100)
            if reached {
                t.invalidate()
                self.ramping = false
                completion?()
            }
        }
    }

    // MARK: - incoming data
    private func parseTreadmillData(_ d: Data) {
        guard d.count >= 4 else { return }
        let flags = UInt16(d[0]) | UInt16(d[1]) << 8
        var i = 2
        speedKmh = Double(UInt16(d[i]) | UInt16(d[i + 1]) << 8) / 100.0
        i += 2
        // a lock-screen toggle arrived while disconnected (app relaunch):
        // act on the belt's real state now that we can see it
        if Date().timeIntervalSince(pendingToggleAt) < 30 {
            pendingToggleAt = .distantPast
            if speedKmh > 0.2 { sendStop() } else { startSession() }
        }
        if flags & 0x0004 != 0, d.count >= i + 3 {
            let dist = Double(UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16)
            if sessionActive && !paused && lastFirmDist >= 0 {
                let delta = dist - lastFirmDist
                if delta > 0 && delta < 10 { distanceM += delta }  // <10 m/s
            }
            lastFirmDist = dist
            i += 3
        }
        if flags & 0x0400 != 0, d.count >= i + 2 {
            let el = Int(UInt16(d[i]) | UInt16(d[i + 1]) << 8)
            if sessionActive && !paused && lastFirmElapsed >= 0 {
                let delta = el - lastFirmElapsed
                if delta > 0 && delta <= 5 { elapsedS += delta }
            }
            lastFirmElapsed = el
            i += 2
        }
        if sessionActive && !paused {
            // simple MET model for walking: MET ≈ 0.9 + 0.5 * km/h
            let dtMin = Date().timeIntervalSince(lastKcalUpdate) / 60
            if dtMin > 0 && dtMin < 1 {
                let met = max(1.2, 0.9 + 0.5 * speedKmh)
                kcal += met * 3.5 * weightKg / 200 * dtMin
            }
            checkGoal()
            LiveActivityController.shared.updateThrottled(state: activityState())
        }
        lastKcalUpdate = Date()
    }

    private func parseSteps(_ d: Data) {
        guard d.count >= 4 else { return }
        let s = Int(UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24)
        if sessionActive && !paused && lastFirmSteps >= 0 {
            let delta = s - lastFirmSteps
            if delta > 0 && delta <= 10 { steps += delta }  // <=10 steps/s
        }
        lastFirmSteps = s
    }

    private func activityState() -> WalkActivityAttributes.ContentState {
        // startedAt is back-dated so the lock-screen timer always reads the
        // true elapsed time, surviving pauses.
        WalkActivityAttributes.ContentState(
            running: sessionActive && !paused,
            startedAt: Date().addingTimeInterval(-TimeInterval(elapsedS)),
            distanceM: distanceM,
            elapsedS: elapsedS,
            steps: steps)
    }
}

// MARK: - CoreBluetooth delegates
extension TreadmillManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [ftmsServiceUUID])
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([ftmsServiceUUID, stepsServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        cpChar = nil
        central.scanForPeripherals(withServices: [ftmsServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        central.scanForPeripherals(withServices: [ftmsServiceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case dataUUID, statusUUID, stepsUUID:
                peripheral.setNotifyValue(true, for: c)
            case cpUUID:
                cpChar = c
                peripheral.setNotifyValue(true, for: c)  // indications
                connected = true
                sendRequestControl()
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let d = characteristic.value else { return }
        switch characteristic.uuid {
        case dataUUID: parseTreadmillData(d)
        case stepsUUID: parseSteps(d)
        case statusUUID:
            // 0x02/0x03 = belt stopped and it wasn't this app's doing:
            // reflect reality — session becomes paused, resumable
            if let s = d.first, s == 0x02 || s == 0x03, sessionActive, !paused {
                paused = true
                rampTimer?.invalidate()
                ramping = false
                schedulePauseAutoEnd()
                LiveActivityController.shared.update(state: activityState())
            }
        default: break
        }
    }
}
