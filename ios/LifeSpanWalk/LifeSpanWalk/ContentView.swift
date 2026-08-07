import SwiftUI

// Brutalist palette
extension Color {
    static let ofaLime = Color(red: 0.84, green: 1.0, blue: 0.0)
    static let ofaRed = Color(red: 1.0, green: 0.23, blue: 0.19)
}

struct ContentView: View {
    @EnvironmentObject var treadmill: TreadmillManager
    @State private var showSettings = false

    @AppStorage("useMiles") private var useMiles = false
    @AppStorage("startEndSpeed") private var startEndSpeed = 2.0
    @AppStorage("goalSpeed") private var goalSpeed = 4.0
    @AppStorage("rampMinutes") private var rampMinutes = 5.0
    @AppStorage("weightKg") private var weightKg = 70.0
    @AppStorage("goalType") private var goalType = "none"
    @AppStorage("goalTimeMin") private var goalTimeMin = 30.0
    @AppStorage("goalKm") private var goalKm = 2.0
    @AppStorage("goalSteps") private var goalSteps = 3000.0

    private var unit: String { useMiles ? "MPH" : "KM/H" }
    private var distUnit: String { useMiles ? "MI" : "KM" }
    private func cv(_ kmh: Double) -> Double { useMiles ? kmh / 1.609344 : kmh }
    private func dist(_ m: Double) -> Double { useMiles ? m / 1609.344 : m / 1000 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if treadmill.maintenanceDue { maintenanceBanner.padding(.top, 10) }
                Spacer(minLength: 10)
                speedBlock
                Spacer(minLength: 10)
                metricsGrid
                Spacer(minLength: 10)
                historyRows
                Spacer(minLength: 12)
                nudgeRow
                    .padding(.bottom, 10)
                mainControls
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Text("WALKER")
                .font(.system(.headline, design: .monospaced).weight(.black))
                .kerning(2)
            Spacer()
            Rectangle()
                .fill(treadmill.connected ? Color.ofaLime : Color.ofaRed)
                .frame(width: 12, height: 12)
            Text(treadmill.connected ? "LINK" : "SCAN")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
            Button { showSettings = true } label: {
                Text("SETTINGS")
                    .font(.system(.caption, design: .monospaced).weight(.black))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(.white, lineWidth: 2))
            }
            .foregroundStyle(.white)
        }
    }

    // MARK: maintenance banner

    private var maintenanceBanner: some View {
        HStack(spacing: 10) {
            Text("⚠︎ MAINTENANCE — LUBE BELT AND HOOVER MOTOR")
                .font(.system(.caption2, design: .monospaced).weight(.black))
                .lineLimit(2)
            Spacer()
            Button { treadmill.dismissMaintenance() } label: {
                Text("X")
                    .font(.system(.caption, design: .monospaced).weight(.black))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(.black, lineWidth: 2))
            }
        }
        .foregroundStyle(.black)
        .padding(10)
        .background(Rectangle().fill(Color(red: 1.0, green: 0.72, blue: 0.0)))
    }

    // MARK: speed

    private var speedBlock: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f", cv(treadmill.sessionActive ? treadmill.targetKmh : 0)))
                .font(.system(size: 92, weight: .black, design: .monospaced))
                .foregroundStyle(treadmill.sessionActive && !treadmill.paused ? Color.ofaLime : .white)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: treadmill.targetKmh)
            HStack(spacing: 14) {
                Text(unit)
                if treadmill.paused {
                    Text("· PAUSED").foregroundStyle(Color.ofaRed)
                } else if treadmill.ramping {
                    Text("· RAMP").foregroundStyle(Color.ofaLime)
                }
                Text("· BELT \(String(format: "%.1f", cv(treadmill.speedKmh)))")
                    .foregroundStyle(.secondary)
            }
            .font(.system(.footnote, design: .monospaced).weight(.bold))
        }
    }

    // MARK: current session metrics (the big grid)

    private var timeText: String {
        let s = treadmill.elapsedS
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var metricsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cell("TIME", timeText)
                Rectangle().fill(.white).frame(width: 2)
                cell("DIST", String(format: "%.2f %@", dist(treadmill.distanceM), distUnit))
            }
            Rectangle().fill(.white).frame(height: 2)
            HStack(spacing: 0) {
                cell("STEPS", "\(treadmill.steps)")
                Rectangle().fill(.white).frame(width: 2)
                cell("KCAL", String(format: "%.0f", treadmill.kcal))
            }
        }
        .overlay(Rectangle().stroke(.white, lineWidth: 2))
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .monospaced).weight(.black))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: lifetime + 30-day history rows (small)

    private func fmtDur(_ s: Int) -> String {
        s >= 3600 ? String(format: "%dH%02d", s / 3600, s / 60 % 60)
                  : String(format: "%dM", s / 60)
    }

    private func signed(_ v: Double, _ fmt: String) -> String {
        String(format: v >= 0 ? "+\(fmt)" : fmt, v)
    }

    private var historyRows: some View {
        let total = treadmill.stats()
        let d30 = Date().addingTimeInterval(-30 * 86400)
        let d60 = Date().addingTimeInterval(-60 * 86400)
        let last = treadmill.stats(since: d30)
        let prev = treadmill.stats(since: d60, until: d30)

        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                smallCell("Σ TIME", fmtDur(total.seconds))
                Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
                smallCell("Σ \(distUnit)", String(format: "%.1f", dist(total.meters)))
                Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
                smallCell("Σ STEPS", "\(total.steps)")
            }
            .overlay(Rectangle().stroke(.white.opacity(0.5), lineWidth: 1))

            HStack(spacing: 0) {
                smallCell("30D TIME", "\(fmtDur(last.seconds)) (\(signed(Double(last.seconds - prev.seconds) / 60, "%.0fM")))")
                Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
                smallCell("30D \(distUnit)", String(format: "%.1f (%@)", dist(last.meters),
                          signed(dist(last.meters - prev.meters), "%.1f")))
                Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
                smallCell("30D STEPS", "\(last.steps) (\(signed(Double(last.steps - prev.steps), "%.0f")))")
            }
            .overlay(Rectangle().stroke(.white.opacity(0.5), lineWidth: 1))
        }
    }

    private func smallCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 9, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
                .kerning(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
    }

    // MARK: controls

    private var nudgeRow: some View {
        HStack(spacing: 12) {
            nudgeButton("−0.1") { treadmill.nudge(-0.1) }
            nudgeButton("+0.1") { treadmill.nudge(+0.1) }
        }
    }

    private func nudgeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.title2, design: .monospaced).weight(.black))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .overlay(Rectangle().stroke(.white, lineWidth: 3))
        }
        .foregroundStyle(.white)
        .disabled(!treadmill.sessionActive || treadmill.paused)
        .opacity(!treadmill.sessionActive || treadmill.paused ? 0.3 : 1)
    }

    private var mainControls: some View {
        Group {
            if !treadmill.sessionActive {
                bigButton("START", fill: .ofaLime, textColor: .black) {
                    treadmill.startSession()
                }
                .disabled(!treadmill.connected)
                .opacity(treadmill.connected ? 1 : 0.3)
            } else {
                HStack(spacing: 12) {
                    bigButton(treadmill.paused ? "RESUME" : "PAUSE",
                              fill: .white, textColor: .black) {
                        treadmill.togglePlayPause()
                    }
                    bigButton("END", fill: .ofaRed, textColor: .black) {
                        treadmill.endSession()
                    }
                }
            }
        }
    }

    private func bigButton(_ label: String, fill: Color, textColor: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.title2, design: .monospaced).weight(.black))
                .kerning(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Rectangle().fill(fill))
        }
        .foregroundStyle(textColor)
    }

    // MARK: settings

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("SPEEDS (\(unit))") {
                    speedSetting("START / END", $startEndSpeed)
                    speedSetting("GOAL SPEED", $goalSpeed)
                    Stepper(value: $rampMinutes, in: 1...20, step: 1) {
                        LabeledContent("RAMP TIME", value: "\(Int(rampMinutes)) MIN")
                    }
                }
                Section("SESSION GOAL") {
                    Picker("GOAL", selection: $goalType) {
                        Text("NONE").tag("none")
                        Text("TIME").tag("time")
                        Text(distUnit).tag("km")
                        Text("STEPS").tag("steps")
                    }
                    .pickerStyle(.segmented)
                    switch goalType {
                    case "time":
                        Stepper(value: $goalTimeMin, in: 5...240, step: 5) {
                            LabeledContent("TARGET", value: "\(Int(goalTimeMin)) MIN")
                        }
                    case "km":
                        Stepper(value: $goalKm, in: 0.5...30, step: 0.5) {
                            LabeledContent("TARGET",
                                value: String(format: "%.1f %@", dist(goalKm * 1000), distUnit))
                        }
                    case "steps":
                        Stepper(value: $goalSteps, in: 500...50000, step: 500) {
                            LabeledContent("TARGET", value: "\(Int(goalSteps)) STEPS")
                        }
                    default:
                        EmptyView()
                    }
                    if goalType != "none" {
                        Text("A couple of minutes before the goal, speed ramps down to START/END; at the goal the session ends and syncs automatically.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Section("UNITS & BODY") {
                    Picker("UNITS", selection: $useMiles) {
                        Text("KM").tag(false)
                        Text("MILES").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $weightKg, in: 30...200, step: 1) {
                        LabeledContent("WEIGHT", value: "\(Int(weightKg)) KG")
                    }
                }
                Section {
                    Text("Belt range 0.8–6.4 km/h. Calories are an approximation from speed, time and body weight. Workouts save to Apple Health on END.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("made by lemonotype & claude")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            .fontDesign(.monospaced)
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { showSettings = false }
                        .fontDesign(.monospaced)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func speedSetting(_ label: String, _ value: Binding<Double>) -> some View {
        Stepper(
            value: value,
            in: TreadmillManager.minKmh...TreadmillManager.maxKmh,
            step: 0.1
        ) {
            LabeledContent(label, value: String(format: "%.1f", cv(value.wrappedValue)))
        }
    }
}
