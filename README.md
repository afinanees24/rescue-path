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
  Services/UWBLink.swift         Nearby Interaction + Multipeer token exchange
  Services/TargetSources.swift   UWB (default), RADAR (rd when rp == 1), SIM
  Model/GuidanceEngine.swift     rule table, 100 ms tick, bracelet writes, rule log
  Model/WorldTracker.swift       world-coordinate target: EMA + outlier rejection, trail
  Views/RadarScreen.swift        the firefighter's single radar screen
  Views/LogSheet.swift           [LOG]: bracelet commands, UWB steps, TEST LEFT/RIGHT, role switch
  Views/BeaconScreen.swift       the hidden person's phone
```

> **Bracelet protocol status:** the app currently sends the earlier 2-byte
> *intensity + duration* commands (as flashed in commit `b9ea988`) and runs the
> 7-rule table from the app spec. The cue + param protocol and three-cue rules
> described above are not wired into the app yet.

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

- **Roles:** at launch pick **FIREFIGHTER** (radar + bracelets; phone faces forward) or **BEACON** (the hidden person's phone; it only joins the UWB session and shows "BEACON ACTIVE" with the distance). Both phones need a U1/U2 chip.
- **One screen, Find My-style:** heading-up 90° / 5 m wedge with a light-blue ping. Target "01" is a teal crosshair at its exact position, held in world coordinates (compass heading + UWB bearing, smoothed, outliers rejected), so turning rotates it around you. A dotted trail shows its last ~1.5 s. When direction drops out it stays dimmed as "01 · LAST KNOWN"; outside the wedge a chevron on the edge points the way to turn. Facing it (within 15°) lights the centre line teal.
- **Footer:** big distance counting in 0.1 m steps, the direction in words ("TO YOUR LEFT · 48°"), the cue actually sent to the bracelets, and `US · RX`. Under 1 m: "ON TARGET · 0.8 M". No fix: "MOVE AROUND · SWEEP SLOWLY".
- **Controls:** `[SCAN]` leaves world-fixed dots (tap again to stop and clear), `[SRC …]` cycles UWB → RADAR → SIM, `[LOG]` opens bracelet commands, UWB state steps, TEST LEFT / TEST RIGHT and the role switch.
- **SIM:** a target ~4.3 m ahead walks toward you at ~0.6 m/s with a slight wobble, then resets.
- **UWB discovery:** Multipeer service type `ff-uwb` (Info.plist lists `_ff-uwb._tcp` and `_ff-uwb._udp`).
