# One Foot After — iOS app

(Internal project/target name is still `LifeSpanWalk`; the user-visible app
name is "One Foot After".)

One-page treadmill controller for the ESP32 console (`firmware/lifespan_console`).
Talks standard BLE FTMS + a custom step-count characteristic.

## Features
- Start → ramps from start speed to goal speed with constant small increments
  over the configured ramp time; End → ramps back down, then stops and saves
  the workout to Apple Health (walking, indoor: distance, kcal, steps).
- Manual +/− (0.1 km/h), Pause/Resume, Stop now.
- Live metrics: speed, time, distance, steps, approximate calories
  (MET model from speed + body weight).
- Settings: start/end speed (default 2 km/h), goal speed (default 4 km/h),
  ramp minutes (default 5), km/miles, body weight.
- Live Activity on the lock screen / Dynamic Island: play-pause button,
  ticking timer, distance.

## Project layout
- `project.yml` — xcodegen spec. After changing it run `xcodegen generate`.
- `LifeSpanWalk/` — app target (BLE manager, HealthKit, Live Activity host, UI).
- `WalkWidgets/` — widget extension (the Live Activity UI).
- `Shared/` — files compiled into both targets (activity attributes, intent).

## Build & run on your iPhone (fastest)
1. `open LifeSpanWalk.xcodeproj`
2. Select the **LifeSpanWalk** target → *Signing & Capabilities* → tick
   *Automatically manage signing*, choose your Team. Repeat for the
   **WalkWidgets** target.
3. Plug in the iPhone, select it as the destination, press ▶ Run.
   (iPhone needs Developer Mode: Settings → Privacy & Security → Developer Mode.)

## TestFlight — headless (recommended)

TestFlight builds expire after 90 days. To push a fresh build with no Xcode
clicking, put an App Store Connect API key (App Manager/Admin role) in
`~/.config/bforp/release.env` (`ASC_KEY_ID`, `ASC_ISSUER_ID`, optional
`ASC_KEY_PATH`; set `WALKER_RELEASE_ENV` to use another file and `TEAM_ID`
for your own team), then:

```bash
ios/publish-testflight.sh 1.1      # archives, signs via cloud, uploads
```

Processing takes ~5–15 minutes; internal testers get the build automatically.

## TestFlight — manual
1. Do the signing step above once.
2. In App Store Connect (appstoreconnect.apple.com): *My Apps → + → New App*:
   platform iOS, name "One Foot After", language, **bundle ID
   `com.lemonotype.lifespanwalk`** (appears in the list after Xcode registers
   it during signing), SKU anything (e.g. `lifespanwalk`).
3. Xcode: *Product → Destination → Any iOS Device (arm64)*, then
   *Product → Archive*.
4. Organizer window opens → *Distribute App → TestFlight & App Store →
   Upload* (accept defaults).
5. Wait ~5–15 min for processing (email arrives). In App Store Connect →
   your app → *TestFlight* tab: the build appears. Export compliance is
   pre-answered (`ITSAppUsesNonExemptEncryption=false`).
6. Under *Internal Testing* create a group, add yourself as tester.
7. Install the TestFlight app on the iPhone, accept the invite, install.

## First launch
- Allow Bluetooth when prompted; the app auto-finds "LifeSpan TR1000"
  (ESP32 must be powered).
- First *Start* asks for Apple Health write permission.
- Lock the phone during a session → Live Activity with play/pause.

## Firmware protocol (for reference)
- FTMS service `0x1826`: Treadmill Data `0x2ACD` (speed 0.01 km/h, distance m,
  elapsed s @1Hz), Control Point `0x2AD9` (0x00 request control, 0x07 start,
  0x08 stop, 0x02 set target speed in 0.01 km/h), Machine Status `0x2ADA`.
- Custom service `7C9A0001-…`: steps char `7C9A0002-…` (uint32 LE, notify).
- Belt range 0.8–6.4 km/h. Firmware watchdog stops the belt if the MCB stops
  answering; 4h max session.
