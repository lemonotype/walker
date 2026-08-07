# LifeSpan TR1000-DT ESP32 console replacement

Goal: fully replace the original desk-integrated console (gone with the desk)
with an ESP32 that controls the treadmill and syncs workouts to iOS Health.

## The protocol (SOLVED — no more guessing)

The console↔MCB link is **Modbus RTU**: slave address `0x01`, **4800 baud 8N1,
5V TTL**. Documented by the [treadspan](https://github.com/blak3r/treadspan)
project ([serial protocol notes](https://github.com/blak3r/treadspan/blob/main/protocol-analysis/serial/README.md),
full bus capture in `protocol-analysis/serial/treadmill-serial-comms-log.txt`)
on a TR1200B — same protocol family.

| Register | Access | Meaning | Known-good frame |
|---|---|---|---|
| `0x0001` | write 1 | START belt | `01 06 00 01 00 01 19 CA` |
| `0x0002` | write 1 | PAUSE/STOP belt | `01 06 00 02 00 01 E9 CA` |
| `0x000A` | write | Speed setpoint, value = 235×mph; **50 = stopped**. Console rewrites it continuously | idle: `01 06 00 0A 00 32 28 1D` |
| `0x000F` | read / write 0 | Step count (computed in the base); console zeroes it at session start/stop | read: `01 03 00 0F 00 01 B4 09` |
| `0x0101` | read | Constant `0x2001` (version/ID?) | `01 03 01 01 00 01 D4 36` |
| `0xD10A` | read | Actual current speed (same encoding) | `01 03 D1 0A 00 01 9D 34` |

Speed check values from the capture: 0.4 mph=94, 0.5=117, 0.6=141, 1.2=282,
2.0=470 → value = 235×mph. Writes are echoed verbatim by the MCB (standard
Modbus FC06 confirmation).

The console **round-robins forever**: read `0x0101` → read `0xD10A` → read
`0x000F` → write `0x000A`=setpoint, roughly every 100 ms per frame. This
explains the "three registers all answering `01 03 02 …`" aliasing from the
sniffing days. Time/calories/distance are NOT on the wire — the console
computes them. Steps are the only base-computed metric.

**Nobody has publicly driven a LifeSpan MCB without its console.** Treadspan
only sniffs. We are breaking new ground; the firmware here replays the
console's exact loop.

## Why the MCB was silent — the three suspects, ranked

### 1. The green wire = safety-key loop (most likely)
Cross-brand precedent is overwhelming: treadmill MCBs ignore valid serial
until the safety/enable loop is closed
([elliotmade console replacement](https://elliotmade.com/2020/06/26/treadmill-controller-reverse-engineering/) — "short out the safety key pins";
[Arduino forum, ALT-6891 board, also 4800 baud](https://forum.arduino.cc/t/control-treadmill-motor-board-with-arduino/567124) — nothing works until the kill-switch pin is tied;
[RPi forum](https://forums.raspberrypi.com/viewtopic.php?t=51547) — SK line sits ~4.5 V with key in, 0 V removed).
LifeSpan's own manuals show a dedicated "SK" wire pair routed to the base, and
their error code AC/DC-8 = "safety key not inserted" is raised by the *lower*
board. On the DT models everything rides the one 7-pin cable — the green
"GND-ish" wire is the prime suspect.

**Test:** with console absent, measure green→black voltage at the treadmill
connector. If it idles pulled up (anything ~3–5 V), tie green to black (GND)
and retry the poll loop. If it idles at 0 V it may want a loop to a different
pin or 5 V — measure, don't guess.

### 2. TX never actually won the bus
BSS138 boards are open-drain with 10 k pull-ups — usually fine at 4800 baud,
but marginal drive or contention is invisible when you only ever sniffed.
The firmware self-checks this: it reads back its own echo (RX and TX share
the bus net) and reports `ECHO FAIL` if what came back isn't what was sent.
Clean echo + no response ⇒ electrical path is fine, suspect #1 or #3.

**Also verify:** orange↔yellow continuity **with power off and console
absent**, measured at the treadmill side. The TR1200B base has *separate*
TX and RX pins (pins 3/4 of its DB9); the previous "continuity when console
is live" reading could have been two distinct, both-idle-high lines. If they
are NOT continuous when dead: orange and yellow are separate directions —
put HV1 on one, HV2 on the other, and if silent, swap.

### 3. Modbus framing/timing
Slaves silently discard frames with >1.5-char inter-byte gaps or bad CRC.
Hardware UART + precomputed CRC (self-tested at boot against the known
`28 1D` frame) handles this. ≥8 ms silence is kept around frames.

## ✅ IT WORKS (2026-07-06, late evening)

Belt started, speed controlled, steps counting — console-less, driven entirely
by the ESP32. Final working recipe:

- **Plug the treadmill in.** (It was unplugged for an unknown stretch of the
  debugging session. Check this first, always, forever.)
- **Final verified wiring** (each element tested by removal):
  - Orange = MCB's RX → our TX (GPIO16 via HV1/LV1). Required.
  - Yellow = MCB's TX → our RX (GPIO17 via HV2/LV2). Required.
    Separate point-to-point 5V UART lines, NOT a shared bus.
  - Red = base-supplied 5V → shifter HV rail. Required. (No VIN injection.)
  - Black = GND, common with ESP32. Required.
  - **Brown ↔ blue bridged together: REQUIRED — this is the motor-enable /
    safety-key loop.** Comms work without it, but the motor will not turn
    (MCB reports running=1, speed stays 0). Splice a switch or the original
    magnetic safety key into this loop for a proper emergency stop.
  - Green: completely unnecessary (comms, start, and run all verified with
    it disconnected). Tape it off.
  - LV2→LV3 pull-up jumper: legacy of the dead-rail era, harmless, kept.
- Protocol: exactly the treadspan register map, Modbus RTU 4800 8N1 slave
  0x01. MCB replies within ~1-3ms on its own line — no echo, no purge needed.
- The whole saga of mangled reads had two real causes: dead 5V rail whenever
  the base was unpowered/unplugged, and every RX artifact that implied
  "shared bus with echo" was cross-domain coupling through the dead rail.

## Bench discoveries (2026-07-06 session)

The original 7-pin "pinout" was measured with the console attached and was
mostly wrong about sourcing. What we established today, console-less:

1. **Red (5V) is CONSOLE-fed, not base-fed.** Without the console it sits at
   ~1V. The level shifter's HV side was unpowered all along, which explains
   every mangled read of this session. Fix: ESP32 VIN (USB 5V) → HV rail.
   With that, both data lines idle clean and solid.
2. **Orange and yellow are separate lines** (the old "continuity" reading was
   a live-circuit false positive). All echo/reply artifacts earlier in the
   session were our own TX coupling through the dead 5V domain.
3. **Green:** grounding it produced a burst of (unreadable, dead-PHY-era)
   MCB activity once; with a healthy PHY it is neither the MCB's RX nor TX
   (full address/baud probes in both orientations: silent). May still be the
   safety key for motor enable — revisit after the MCB talks.
4. **Address/baud sweeps (1-247 × 2400/4800/9600/19200, both pin
   orientations, healthy PHY): total silence.** The MCB is not listening.
5. **Leading theory — the MCB is asleep.** Treadspan's TR1200B notes say the
   12V pin is live "only when the console is on/awake" → 12V is
   console→base and is the wake/presence signal. Brown/blue (~0V now,
   "12V" historically i.e. console-powered) are that rail. Next experiment:
   inject 12V into brown/blue from a wall adapter (GND common with black).

Firmware diagnostic commands (USB serial, 115200): `p` poll toggle,
`l` listen-only, `b` cycle baud, `S` swap TX/RX lines, `z` address×baud
probe, `w` edge-timing waveform capture, `a` ADC scope via GPIO4 tap,
`i` RX polarity, `s`/`x`/`1-9`/`+`/`-` belt controls.

## Current wiring (from the sniffing sessions)

7-pin treadmill connector:
- **Red** = 5 V → shifter HV
- **Black** = GND → shifter GND + ESP32 GND
- **Orange** = bus → HV1, LV1 → GPIO16 (RX2)
- **Yellow** = bus → HV2, LV2 → GPIO17 (TX2)
- **Green** = suspected safety key — measure, then likely tie to GND
- **Brown, Blue** = 12 V — never connect

ESP32: 3.3 V → LV, GND → shifter LV-side GND. (The old GPIO4 tap is no longer
needed — the firmware reads on GPIO16.)

## Bench procedure

⚠️ The belt may actually start. Treadmill on the floor, nobody on it, hand
near the power switch.

1. Power off. Verify orange↔yellow continuity at the treadmill connector
   (suspect #2). Note result.
2. Power on, console absent. Measure green→black voltage. Note result.
3. Flash `firmware/lifespan_console/`, open serial monitor @115200.
   Polling starts automatically. Watch for:
   - `ECHO FAIL` → electrical problem (suspect #2). Fix before anything else.
   - Clean echoes, all timeouts → suspect #1: tie green to GND, watch again.
   - Responses appear → **we own the bus.** `s` to start, `1`–`9` for speed,
     `x` to stop.
4. Log everything; update this README with what the green wire measured and
   which change made the MCB answer.

## Roadmap after bus control works

1. Solid control loop: start/stop/speed with ramping, watchdog (belt stops if
   firmware hangs), physical E-stop still recommended.
2. UI: buttons/encoder + small display, or phone-only.
3. **iOS Health sync** — the original motivation. Best path: ESP32 advertises
   BLE **FTMS (Fitness Machine Service)** treadmill profile; then any standard
   fitness app — and via one of them, Apple Health — picks it up. Steps come
   from register `0x000F`, speed from `0xD10A`; distance/time we integrate
   ourselves (the wire doesn't carry them).

## Sources
- https://github.com/blak3r/treadspan (protocol, register map, capture log)
- https://gist.github.com/daeken/a3d3c4da11ca1c2d2b84 (comment thread: pinout
  measurements, MCB MCU is an STM32F102C6T6A, no RS-485 transceiver = plain
  5 V UART)
- https://elliotmade.com/2020/06/26/treadmill-controller-reverse-engineering/
- https://forum.arduino.cc/t/control-treadmill-motor-board-with-arduino/567124
- https://forums.raspberrypi.com/viewtopic.php?t=51547
