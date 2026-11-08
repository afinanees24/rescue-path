# Firefighter Radar (hackathon demo)

An iPhone "through-wall radar" display for firefighters, fed by an HLK-LD2410B mmWave
sensor on an ESP32. The phone only shows the map: haptic alerts are handled by separate
ESP32 bracelets (built by a teammate), and the phone does not vibrate.

```
ios/RadarView/                SwiftUI app (RadarView.xcodeproj, scheme RadarView)
firmware/fake_radar/          ESP32 sketch: BLE "FF-RADAR" sending simulated readings
firmware/radar_bridge/        ESP32 sketch: same BLE service, real LD2410B over UART2
```

## What the app shows

- **Floor plan** of a five-room house, top-down. Drag the blue marker (you) to move.
- **Radar cone**: 120°, 6 m range, rings every metre, sweeping. It points where the phone
  faces (compass). If there's no compass, or you twist two fingers on the map, it switches
  to manual heading, with rotate buttons for gloves.
- **Reading band**: the LD2410B reports *distance only*, so a reading shows as a glowing
  arc across the cone at that distance. **Orange = moving. Pulsing red = still,
  labelled "POSSIBLY UNCONSCIOUS"** (still people are the top priority).
- **SCAN mode**: turn slowly in place. Each reading is stored with the compass bearing
  at that moment and left as a blip at that bearing and range. Blips fade after 30 s.
  Where blips cluster is where the person is.
- **Bottom sheet**: current detections (distance, bearing, moving/still, last seen),
  a timestamped alert log (e.g. `Still person 3.4 m, bearing 87° — possibly unconscious`)
  and settings.
- **Status bar**: SIMULATED / LIVE badge (tap it to switch), BLE state, update rate, heading.

**Simulated mode** (the default) places 1–3 fake people in the house: one always lies still
in Bedroom 2 and the others wander. Like the real sensor, it reports only people inside the
cone, and the nearest moving and nearest still person win. Settings → "Show simulated people"
reveals where they really are, which is handy for showing judges that the scan blips line up.

**Live mode** connects over Bluetooth to whichever ESP32 sketch is running.

## Run the app on an iPhone

1. Open `ios/RadarView/RadarView.xcodeproj` in Xcode (27.x was used to build it).
2. Select the **RadarView** target → *Signing & Capabilities* → tick *Automatically manage
   signing* and pick your **Team** (a free Apple ID works). If Xcode complains about the
   bundle ID, change `com.firefighterhaptics.RadarView` to something unique.
3. Plug in the iPhone, unlock it, and pick it as the run destination at the top of Xcode.
4. On the phone, turn on **Developer Mode** if asked: Settings → Privacy & Security →
   Developer Mode, then restart.
5. Press **Run** (⌘R). The first time, trust the developer certificate on the phone:
   Settings → General → VPN & Device Management.
6. Allow **Location** (for the compass) and, when you switch to LIVE, **Bluetooth**.

iOS 17 or later is required. The app is portrait-only and keeps the screen awake.

To check that it compiles without signing (this is what CI or a quick check uses):

```bash
xcodebuild -project ios/RadarView/RadarView.xcodeproj -scheme RadarView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

> Tip: in the demo, stand facing the "top" of the map and tap Settings → *Align map to the
> way I'm facing*, so turning your body turns the cone the same way on screen.

## Flash the ESP32 (Arduino IDE)

One-time setup:

1. Arduino IDE → Settings → *Additional boards manager URLs*, add
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`.
2. Boards Manager: install **esp32 by Espressif Systems**.
3. Library Manager: install **NimBLE-Arduino** (by h2zero, version 2.x) and, for the
   real radar, **ld2410** (by ncmreynolds).
4. Tools → Board → **WEMOS LOLIN32 Lite**, and pick the board's serial port.

Then open a sketch, click **Upload**, and open the Serial Monitor at **115200** baud to
see the JSON it sends.

| Sketch | Use it for |
|--------|-----------|
| `firmware/fake_radar/fake_radar.ino` | Testing the app with no radar attached. Sends a person walking between about 1.5 and 4.5 m and a still person at about 3.4 m. |
| `firmware/radar_bridge/radar_bridge.ino` | The real LD2410B. Prints `LD2410B: connected` at boot if the wiring is right. |

In the app, tap the badge so it says **LIVE**. The status bar goes *Scanning… →
Connecting… → FF-RADAR connected* and the update rate should read about **5.0 Hz**. If the
ESP32 resets or goes out of range, the app reconnects on its own.

## LD2410B wiring

| LD2410B pin | Connect to |
|-------------|-----------|
| VCC | **5 V** |
| GND | **GND**, shared with the ESP32 (required) |
| TX  | ESP32 **GPIO16** (UART2 RX) |
| RX  | ESP32 **GPIO17** (UART2 TX) |
| OUT | not used |

- TX and RX **cross over**: the sensor's TX goes to the ESP32's RX pin.
- The UART runs at **256000 baud**, the LD2410B's default. Its serial pins use 3.3 V
  logic, so they connect straight to the ESP32 with no level shifter.
- **Power:** the LD2410B wants 5 V. Many LOLIN32 Lite boards have no labelled 5 V
  pin. If yours doesn't, power the sensor from a 5 V source (the USB 5 V line, or a
  power bank via a USB breakout) and **connect its GND to the ESP32's GND**.
- To use other pins, change `RADAR_RX_PIN` / `RADAR_TX_PIN` at the top of
  `radar_bridge.ino`.

## BLE interface

| | Value |
|---|---|
| Device name (advertised in the scan response) | `FF-RADAR` |
| Service UUID (advertised) | `8E2F0001-6B1D-4C6A-9F3E-2A7C5D9B1E40` |
| Characteristic UUID (read + notify) | `8E2F0002-6B1D-4C6A-9F3E-2A7C5D9B1E40` |
| Rate | 5 notifications per second |

Each notification is one UTF-8 JSON object:

```json
{"moving":{"dist":210,"energy":64},"still":{"dist":340,"energy":41}}
```

- `dist`: distance in **centimetres**; `0` means no target of that kind.
- `energy`: signal strength, **0–100**.

The app finds the device by **name**. It subscribes to the characteristic above, or, if
that UUID isn't found, to the first notify characteristic on the device. Missing fields
count as 0. The ESP32 requests a 185-byte MTU, which iPhones accept, so a frame (~70 bytes)
fits in one notification. The app can also re-join a frame that arrives split across
several notifications.
