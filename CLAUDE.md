# CLAUDE.md — AI agent briefing for the Walker repo

You are working on an open-source console replacement for LifeSpan
under-desk treadmills (developed on a TR1000-DT). Read this before touching
anything; it encodes lessons that cost real debugging hours.

## Repo layout

- `firmware/lifespan_console/` — single-sketch ESP32 firmware (Arduino).
  Modbus RTU master on the treadmill bus + BLE FTMS server.
- `ios/LifeSpanWalk/` — SwiftUI app "Walker" (xcodegen project; app target +
  WalkWidgets Live Activity extension). After editing `project.yml`, run
  `xcodegen generate` — this RESETS signing team selection in Xcode.
- `android/` — Kotlin/Compose app "Walker" (minSdk 31). `gradle
  assembleRelease` → signed APK (keystore + password are intentionally
  public, see android/README.md).
- `docs/reverse-engineering-notes.md` — the full hardware war story. Read it
  before any hardware-adjacent change.

## Build commands

- Firmware: `arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app .`
  (huge_app is REQUIRED — BLE overflows the default partition). Upload with
  the same FQBN. Serial console at 115200 has diagnostic commands
  (s/x/1-6/+/-/d=dump, w=edge-timing waveform analyzer, z=Modbus addr×baud
  scanner, p=poll toggle, m=active mode, l=listen).
- iOS: `xcodegen generate && xcodebuild -project LifeSpanWalk.xcodeproj
  -scheme LifeSpanWalk -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build`
- Android: `gradle assembleRelease` (needs local.properties with sdk.dir).

## Protocol facts (verified on hardware)

- MCB = Modbus RTU slave 0x01, 4800 8N1, 5V UART. Registers: 0x0001 w1=start,
  0x0002 w1=stop, 0x000A speed setpoint (value = 146.03×km/h = 235×mph,
  50 = stopped, rewrite continuously like the real console), 0x000F steps
  (w0 resets), 0x0101 version (0x2001), 0xD10A actual speed.
- Orange = MCB RX (our TX, GPIO16), Yellow = MCB TX (our RX, GPIO17).
  SEPARATE point-to-point lines — not a shared bus, no echo.
- MCB replies within ~1–3 ms of a request. Belt range 0.8–6.4 km/h.
- Brown = +12V console supply; Blue = enable sense — they must be bridged or
  the MCB accepts commands but the motor never turns.
- Red = weak 5V bias rail: powers the level shifter HV side ONLY. It
  collapses under >~30 mA. Never try to power the ESP32 from it.

## Sharp edges (do not rediscover these)

1. **Never call `indicate()`/`notify()` from a BLE callback** (Bluedroid).
   A control-point write burst deadlocks the BT task against `loop()` and
   freezes the whole firmware — with the belt running. Set a flag; send from
   `loop()`. (The MCB keeps the belt at the last setpoint FOREVER if the
   master dies. Treat firmware hangs as a safety issue.)
2. **Motor EMI corrupts up to ~50% of telemetry replies while someone walks.**
   This is normal. Any comms watchdog must key on "any reply bytes"
   (liveness), never "CRC-valid replies" — the original clean-reply watchdog
   stopped the belt randomly mid-walk.
3. **Apps must accumulate deltas, not absolute counters.** Firmware counters
   reset on belt starts and ESP32 reboots, and stale values reappear on
   reconnect. Both apps cap per-notification deltas (≤10 steps, <10 m, ≤5 s
   per ~1 s update) and treat bigger jumps as artifacts that only resync the
   reference. Preserve this pattern in any port.
4. **iOS App Intents:** `authenticationPolicy` must be a STORED property
   (`static var x: T = .alwaysAllowed`) — computed properties are silently
   dropped by the metadata extractor and lock-screen buttons start demanding
   Face ID again.
5. UART1 on ESP32: never begin() with pin -1 — the core falls back to
   GPIO9/10 (flash pins) and corrupts everything.
6. Speed values are unit-less on the wire. Both apps are km/h-native with
   display conversion. The original console displayed km/h in Europe.

## Product behaviors to preserve in ports

Ramp engine (start speed → goal over N minutes, 5 s steps; quick ~15 s ramp
on resume; goal-approach wind-down 2 min out, then auto-end + health sync),
pause auto-end after 1 h, 1.5 s debounce on lock-screen toggles, honest
pause-state when the machine stops itself (FTMS status 0x02/0x03),
maintenance reminder every 90 days or 30 walked hours, delta-capped counters,
session history → lifetime + 30-day stats.
