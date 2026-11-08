# RescuePath

Two tools for the worst day of a wildfire, built for HackUTD 2026:

- **RescuePath bracelets**: haptic wrist guidance for firefighters in zero-visibility rooms. Two vibrating bracelets steer the wearer toward a detected person and around obstacles; every detection reports up to an incident-command map so no household is overlooked. *Track: "The Worst Day, at Scale: Intelligent Catastrophe Response."*
- **Drone-Eye**: an AI drone survey for disaster zones (wildfire, hurricane or flood). A Nemotron agent flies the street home by home: it rates each home's damage, checks for people, ranks who needs help first, and files a claim-ready PDF with photos and a payout estimate. *Tracks: State Farm, NVIDIA.* See [`drone-eye/`](drone-eye/).

The two work together: the drone survey shows responders which homes may still have people in them, and the bracelets guide a firefighter to them inside.

## RescuePath bracelets: how it works

| Part | Hardware | Job |
| --- | --- | --- |
| Waist unit | Lolin32 Lite + HC-SR04 ultrasonic | Streams obstacle distance over BLE at 10 Hz |
| Bracelet L / R | Lolin32 Lite + vibration motor | Plays one of three haptic cues, patterns run on-board |
| Phone (brain) | iPhone, Swift | Connects to all three boards, ranges the target, picks the cue, draws the radar view |
| Person detection | 24 GHz mmWave radar (production) / UWB between two iPhones (demo) | Distance + bearing to the person |

## The three cues

| Cue | Wrists | Feel | When |
| --- | --- | --- | --- |
| **Forward** | Both, together | Slow strong pulses (250 ms on / 250 ms off, intensity 220) | Heading is within ±15° of the person |
| **Stop** | Both, together | Solid 255, continuous | Obstacle under 60 cm, or within 1 m of the person. Overrides everything |
| **Turn** | One wrist only | Continuous buzz, 70 → 255 as the heading error shrinks from 90° to 15° | Off heading; buzz on the side to turn toward, louder as you get it right |

No target fix: wrists silent, screen shows "Searching"; the wearer turns in place until a Turn cue appears. First-time wearer briefing: *"Both wrists pulsing: walk. Both wrists hard and steady: stop. One wrist: turn that way, it gets stronger as you get it right."*

## Repo layout

```
rescue-path/
├── README.md
├── firmware/                  RescuePath bracelet + waist unit (Arduino, ESP32)
│   ├── bracelet_ble/          bracelet_ble.ino: plays the three haptic cues over BLE
│   └── waist_ultrasonic/      waist_ultrasonic.ino: obstacle distance + radar slot over BLE
└── drone-eye/                 Drone-Eye damage assessment (Python, runs on Windows or Mac)
    ├── run.py                 start here
    ├── droneeye/              camera, house lookup, detection, AI rating, pricing, web server
    ├── static/                dashboard (3D house view, live camera, map)
    ├── data/parcels.json      demo neighborhood (fictional addresses and policies)
    └── README.md              full setup and run guide
```

The iPhone app (the phone "brain" for the bracelets) is not in this repo yet.

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
| 0 | Cue | `0` off · `1` forward pulse · `2` stop · `3` turn |
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

Board: **WEMOS LOLIN32 Lite** (`esp32:esp32:lolin32-lite`). Both bracelets run the **same binary** — the board picks its own name at boot: GPIO 32 open = `Bracelet-L`, GPIO 32 tied to GND = `Bracelet-R`.

```bash
arduino-cli compile --fqbn esp32:esp32:lolin32-lite firmware/bracelet_ble
arduino-cli upload  --fqbn esp32:esp32:lolin32-lite -p /dev/cu.usbserial-10 \
  --upload-property upload.speed=460800 firmware/bracelet_ble
```

Upload speed matters: the default 921600 fails on these CH340 cables, 460800 works. The board prints `advertising <name>` at 115200 on boot. Test the motor from nRF Connect by writing `01 00`, `02 00`, `03 FF`, `00 00` to the bracelet characteristic.

## Demo note

The production design uses a 24 GHz mmWave radar on the waist unit to detect people through smoke and interior walls with no tag. That module didn't arrive in time, so the demo feeds the same slot with UWB (Nearby Interaction) between two iPhones. Everything downstream is unchanged.

## Drone-Eye

Software for the drone's camera. It runs on a laptop; the drone's live view comes in as a camera feed.

### What it does

| Step | How |
| --- | --- |
| **Which house is this?** | Projects the camera's view from the drone's GPS, height, heading and camera tilt onto the ground and matches it to a property record (address, size, year built, policy). A location module can POST the pose, or name the house directly. |
| **How bad is the damage?** | NVIDIA Nemotron (vision model) rates the home (No damage, Affected, Minor, Major, Destroyed) plus each part: roof, walls, windows, garage, car, yard. It also lists hazards. Switch between **wildfire, hurricane/wind and flood**; each changes what the AI looks for (for floods, how high the water reached). |
| **Who pays?** | Wildfire and wind go to the homeowners policy (wind uses a hurricane deductible). Floods are only covered by a separate flood policy, so homes without one show the loss as uninsured. |
| **What will the claim cost?** | Turns the rating into a payout estimate (house, other structures, belongings, debris removal, minus the deductible) with a low–high range. |
| **Is anyone there?** | YOLO spots people and animals on every frame. Radar detections can be POSTed in too. Each alert shows how many people live at that address. |
| **AI survey agent** | Nemotron 3.5 Super VL runs the survey with tool calls: look at the home, ask the pilot for a better angle when unsure, look up the policy, check for people, raise alerts, price the claim, file the PDF, then pick the next most urgent home. Every step shows live in an agent log. Without an NVIDIA key, the same tools run on fixed rules. |
| **Who needs help first?** | Ranks every home: people seen, then occupants not confirmed safe in a badly damaged home, then unsafe sites, uninsured losses, damaged, no damage. A "not checked yet" list makes sure no home is missed. |
| **Evidence photos** | Saves the exact camera frame of every AI rating with damage boxes drawn on (roof, walls…). Press **Take photo** (or **P**) to grab a frame yourself. |
| **Claim report** | One click gives a PDF for the adjuster: a one-sentence answer, the marked photo, damage scale, payout breakdown, safety, people, next-steps checklist and sign-off. Also one PDF for the whole survey. |
| **Show it simply** | A plain-language dashboard: a 3D model of the house that burns, collapses and smokes to match the AI's rating, a help-needed list, payout, a "safe to go in?" gauge, the live camera and a street map. |

### Run it

```bash
cd drone-eye
python -m venv .venv
# Windows:  .\.venv\Scripts\Activate.ps1      Mac:  source .venv/bin/activate
pip install -r requirements.txt
# Windows:  $env:NVIDIA_API_KEY="nvapi-..."      Mac:  export NVIDIA_API_KEY="nvapi-..."
python run.py --source 0 --provider nemotron --max-assess-per-house 20 --disaster wildfire --report-to "State Farm Claims"
```

Open http://localhost:8000 and press **Start agent**, or add `--agent` to the command. `--disaster` can be `wildfire`, `hurricane` or `flood`, or switch from the dashboard's Disaster menu. Get a free NVIDIA key at build.nvidia.com and set it in your terminal; never commit it. `--source` takes a webcam number, a video file or a stream URL. Run `python run.py --list-cameras` to see your options.

**Using the Potensic Atom drone:** it has no open API, so mirror the phone running PotensicPro to the laptop (scrcpy on Android, an AirPlay receiver on iPhone). Capture that window in OBS, click **Start Virtual Camera**, and pass that camera's number to `--source`.

### Talking to Drone-Eye from other parts

| Endpoint | Sends |
| --- | --- |
| `POST /api/telemetry` | Drone pose: `{"lat":34.19,"lon":-118.13,"alt_m":30,"heading_deg":0,"gimbal_pitch_deg":-45}`, or `{"target_address":"2441 Cedar Ridge Dr"}` |
| `POST /api/radar` | Signs of life: `{"detections":[{"type":"breathing","confidence":0.8,"range_m":12,"azimuth_deg":-10}]}` |
| `GET /api/state` | Everything on the dashboard, as JSON (could feed the incident-command map) |
| `GET /api/priorities` | Every home ranked by who needs help first, plus homes not checked yet |
| `POST /api/agent/start` · `/api/agent/stop` · `GET /api/agent` | Run the Nemotron survey agent and read its step-by-step log |
| `GET /api/property/{parcel_id}/claim.pdf` · `GET /api/claims.pdf` | Claim PDF for one home, or for every rated home |
| `GET /api/report.csv` | Claims list for adjusters |

Full details are in [`drone-eye/README.md`](drone-eye/README.md).

**Demo note:** the 18 addresses and policies in `drone-eye/data/parcels.json` are fictional. Payouts are a first-pass triage estimate for an adjuster to review, not a coverage decision.
