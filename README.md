# RescuePath

Haptic wrist guidance for firefighters in zero-visibility rooms. Two vibrating bracelets steer the wearer toward a detected person and around obstacles; every detection reports up to an incident-command map so no household is overlooked.

Built for HackUTD 2026 — "The Worst Day, at Scale: Intelligent Catastrophe Response."

## How it works

| Part | Hardware | Job |
| --- | --- | --- |
| Waist unit | Lolin32 Lite + HC-SR04 ultrasonic | Streams obstacle distance over BLE at 10 Hz |
| Bracelet L / R | Lolin32 Lite + vibration motor | Plays one of three haptic cues, patterns run on-board |
| Phone (brain) | iPhone, Swift | Connects to all three boards, ranges the target, picks the cue, draws the radar view |
| Person detection | 24 GHz mmWave radar (production) / UWB between two iPhones (demo) | Distance + bearing to the person |

## The three cues

| Cue | Wrists | Feel | When |
| --- | --- | --- | --- |
| **Forward** | Both, together | Light flutter (50 ms on / 50 ms off) | Heading is within ±15° of the person |
| **Stop** | Both, together | Hard pulses (255 for 300 ms, off 200 ms) | Obstacle under 60 cm, or within 1 m of the person. Overrides everything |
| **Turn** | One wrist only | Continuous buzz, 70 → 255 as the heading error shrinks from 90° to 15° | Off heading; buzz on the side to turn toward, louder as you get it right |

No target fix: wrists silent, screen shows "Searching"; the wearer turns in place until a Turn cue appears. First-time wearer briefing: *"Both wrists fluttering: walk. Both wrists hard: stop. One wrist: turn that way, it gets stronger as you get it right."*

## Repo layout

## BLE contract

Service UUID (all boards): `12345678-1234-5678-1234-56789abcdef0`

**Waist → phone** — notify on `12345678-1234-5678-1234-56789abcdef2`, JSON at 10 Hz:

```json
{"us":87,"rp":1,"rd":230,"re":64}
```
`us` ultrasonic cm (−1 = no echo) · `rp` radar present · `rd` radar cm · `re` radar energy 0–100 (`rp/rd/re` are placeholders until the radar module is wired).

**Phone → bracelet** — write 2 bytes to `12345678-1234-5678-1234-56789abcdef1`, without response:

| Byte | Meaning | Values |
| --- | --- | --- |
| 0 | Cue | `0` off · `1` forward flutter · `2` stop · `3` turn |
| 1 | Param | Intensity 70–255 for cue 3, ignored otherwise |

Patterns loop on the bracelet until a new cue arrives, so the app writes only on change. Send `3, intensity` to the turn-side wrist and `0` to the other; `1` or `2` to both. A bracelet that hears nothing for 2 s stops itself.

## Wiring

| Board | Pin | Connects to |
| --- | --- | --- |
| Waist | 14 | HC-SR04 TRIG |
| Waist | 27 | HC-SR04 ECHO |
| Waist | 3V / GND | HC-SR04 VCC / GND |
| Waist | 16 / 17 | LD2410 radar TX / RX (when fitted; power from battery +) |
| Bracelet | 26 | Vibration motor module (PWM) |
| All | JST | 3.7 V LiPo, charges over USB-C |

## Flashing

Arduino IDE 2 with the `esp32` board package. Board: **WEMOS LOLIN32 Lite**. Tools → Upload Speed → **115200** (921600 fails on these clones). Set `NAME` to `Bracelet-L` or `Bracelet-R` before flashing each bracelet. Test from nRF Connect by writing `01`, `02`, `03 FF`, `00` to the bracelet characteristic.

## Demo note

The production design uses a 24 GHz mmWave radar on the waist unit to detect people through smoke and interior walls with no tag. That module didn't arrive in time, so the demo feeds the same slot with UWB (Nearby Interaction) between two iPhones. Everything downstream is unchanged.

---

## iOS app (RadarView)

The phone side lives in `ios/RadarView` (Xcode project `RadarView.xcodeproj`, scheme `RadarView`, iOS 17+). It is a minimal, monochrome "tactical handheld radar" display plus the guidance logic that drives the bracelets.

```
ios/RadarView/RadarView/
  Services/BoardLink.swift       BLE to Waist, Bracelet-L, Bracelet-R (contract above)
  Services/UWBLink.swift         Nearby Interaction session, camera-assist control
  Services/BeaconPeripheral.swift  beacon phone: BLE token exchange (…def9 / …defA / …defB)
  Services/MotionHeading.swift   gyro heading from the attitude matrix
  Model/BearingLatch.swift       latched absolute bearing between UWB directions
  Model/GuidanceEngine.swift     rule table, 100 ms tick, bracelet writes, rule log
  Model/WorldTracker.swift       world-coordinate target: EMA + outlier rejection, trail
  Views/RadarScreen.swift        the firefighter's single radar screen
  Views/LogSheet.swift           [LOG]: bracelet commands, UWB steps, TEST LEFT/RIGHT, role switch
  Views/BeaconScreen.swift       the hidden person's phone
```

### Running it on an iPhone

1. Open `ios/RadarView/RadarView.xcodeproj` in Xcode.
2. RadarView target → *Signing & Capabilities* → pick your own **Team** (the project is committed with one teammate's Personal Team).
3. Turn on Developer Mode on the phone (Settings → Privacy & Security → Developer Mode), plug it in, choose it as the run destination and press ⌘R.
4. First launch: trust the developer certificate (Settings → General → VPN & Device Management) and allow Bluetooth, Location, Local Network and Nearby Interaction (and Camera on iPhones that need camera-assisted UWB direction).

Compile check without signing:

```bash
xcodebuild -project ios/RadarView/RadarView.xcodeproj -scheme RadarView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

### Using it

Zero setup: open the app on both phones. Each remembers its role (FIREFIGHTER or BEACON).

- **Token exchange over BLE (no Wi-Fi, no Multipeer):** the beacon phone is a BLE peripheral advertising service `12345678-1234-5678-1234-56789abcdef9`. `…defA` (read + notify) holds its archived NI discovery token; `…defB` (write, with response) receives the firefighter's. The firefighter's central (already scanning for the boards on `…def0`) also scans for `…def9`, reads `…defA`, runs its NI session, and writes its own token to `…defB`. Invalidations and BLE drops recover automatically.
- **Direction:** if the phone reports `supportsDirectionMeasurement`, UWB alone. Otherwise camera assistance (shared ARSession) runs only until the first valid direction, then turns off; it comes back after 10 s without one.
- **Gyro latch:** heading comes from CoreMotion (`.xArbitraryZVertical`, 50 Hz), projecting the phone's back axis onto the horizontal plane (no Euler yaw). Each valid UWB direction latches the target's absolute bearing; between directions the bearing is latch − heading, so guidance keeps working outside UWB's ±45° field.
- **Bracelets:** `[cue, param]` to `…def1` without response (0 off · 1 forward · 2 stop · 3 turn with intensity 70–255). Stop under 60 cm ultrasonic or 1 m to the target; turn when more than 15° off (forward until 25° once aligned); off with no fix. Written on change and re-sent every 1 s (the boards stop after 2 s of silence). Only `us` is read from the waist JSON.
- **Any distance:** the scope auto-ranges 5 → 10 → 20 → 40 m. Without UWB for 2 s but with the BLE link up it shows **FAR · BLE** with a rough RSSI distance and keeps steering toward the last bearing; with neither, **OUT OF RANGE** and the bracelets go quiet.
- **Mounting:** firefighter phone on the chest, screen facing you, back facing forward (UWB looks out of the back). Beacon at chest height or in a front pocket, top up, no metal in between.
- **Testing:** launch argument `-role firefighter|beacon` picks the role; every connection step is logged (subsystem `com.firefighterhaptics.RadarView`, category `UWB`), to stderr, and to `Documents/uwb-log.txt` in the app container for walk tests.
