# Walker — Android app

Android twin of the iOS app: connects to the ESP32 console
(`firmware/lifespan_console`) over BLE FTMS and mirrors the same features.

## Just want to use it?

Install `Walker-v1.0.apk` (sideload: allow "install unknown apps" for your
browser/file manager). Android 12+.

- Grant Bluetooth + notification permissions on first launch; it finds the
  treadmill by itself.
- START ramps from your start/end speed to the goal speed; PAUSE/RESUME and
  END live both in the app and on the lock-screen notification (no unlock
  needed — Android notification actions just work).
- Session goals (time / distance / steps) ramp down as you approach, then
  end + sync automatically. Paused sessions auto-end after an hour.
- Sessions sync to **Health Connect** (walking session, steps, distance,
  calories) if it's installed; grant permissions when prompted on first START.
- Lifetime and last-30-days totals accumulate locally from ended sessions.

## Building

```
brew install openjdk@17 gradle android-commandlinetools   # or Android Studio
sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools"
echo "sdk.dir=$ANDROID_HOME" > local.properties
gradle assembleRelease
```

APK lands in `app/build/outputs/apk/release/`.

Note: the release keystore + password in `app/build.gradle.kts` are public —
fine for the community sideload trust model (you're trusting the repo either
way), but generate your own keystore if you distribute a fork.
