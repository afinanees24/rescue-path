# Drone-Eye: wildfire property assessment from a drone camera

HackUTD 2026 · State Farm track

A drone flies over a burned neighborhood. For every house it looks at, Drone-Eye:

1. **Identifies the property.** It projects the camera's center ray from the drone's GPS, altitude, heading and gimbal pitch onto the ground, then matches that point to a parcel. The parcel record gives the address, structure details and policy.
2. **Assesses damage the way an adjuster would.** A vision model (NVIDIA Nemotron, Claude or Gemini, whichever key you set) returns a structured report: a CAL FIRE DINS damage category, damage %, the condition of the roof, walls, garage, vehicles and so on, hazards, notes and recommended actions.
3. **Prices the claim.** It estimates dwelling, other-structures, contents and debris-removal losses against the policy limits and deductible, and shows a confidence-weighted range.
4. **Flags signs of life.** On-device YOLO looks for people and animals on every frame. Radar hits from your radar module are placed on the map and merged into one alert feed. Each alert shows how many occupants and pets the policy has on file.

The camera is simulated with a webcam, an iPhone, a video file or a Raspberry Pi stream. To demo it, point the camera at photos of burned houses.

```
camera ──► frame ──► YOLO (people/animals/vehicles) + flame detector ──► HUD overlay ──► /video.mjpg
                │
location module ──► pose ──► look-point ──► parcel DB ──► address / policy
                │
                └──► Nemotron / Claude / Gemini vision (background, ~every 10 s per house) ──► DINS category + components
                                                                              │
radar module ──► /api/radar ──► geolocate ──► alerts ◄────────────────────────┘──► pricing ──► dashboard / CSV
```

## Quick start

Python 3.10+ on Windows or macOS. Set the API key in your terminal each session; never put it in a file in this repo.

**Windows (PowerShell)**
```powershell
cd drone-eye
python -m venv .venv
.\.venv\Scripts\Activate.ps1          # if blocked: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
pip install -r requirements.txt
$env:NVIDIA_API_KEY="nvapi-..."         # from build.nvidia.com
python run.py --source 0 --provider nemotron --assess-interval 6 --max-assess-per-house 20
```

**macOS (Terminal)**
```bash
cd drone-eye
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export NVIDIA_API_KEY="nvapi-..."
python run.py --source 0 --provider nemotron --assess-interval 6 --max-assess-per-house 20
```

Open http://localhost:8000. The original dashboard is still at `/classic`. If the AI ratings look wrong, `/api/debug/ai` shows Nemotron's last raw reply. `python run.py --list-cameras` lists the camera numbers you can pass to `--source`. Run only one copy at a time: on Windows a second copy can quietly share port 8000.

### Using the Potensic Atom drone
The Atom has no open API, so you mirror the phone running PotensicPro to the PC (scrcpy on Android, an AirPlay receiver on iPhone). In OBS, add a Window Capture of the mirror and click **Start Virtual Camera**. Then run with `--source 1` (or the number `--list-cameras` shows).

## Camera options

| Setup | Command |
|---|---|
| Laptop webcam | `python run.py --source 0` |
| **iPhone on a Mac (Continuity Camera)**: the phone shows up as a webcam | `python run.py --source 1` (try 0/1/2) |
| **iPhone browser**: phone streams to the laptop | `python run.py --source phone`, then `cloudflared tunnel --url http://localhost:8000` and open `https://<tunnel>/phone` on the phone. Safari only allows camera access over HTTPS, which is why you need the tunnel. |
| Raspberry Pi camera / IP-camera app | `python run.py --source http://<pi-ip>:8080/stream.mjpg` |
| Recorded footage or one photo | `python run.py --source flight.mp4` / `--source house.jpg` |

## Integration contract (for the other modules)

**Location module → `POST /api/telemetry`** (send ≥1 Hz; the app falls back to the simulator after 15 s of silence):
```json
{"lat": 34.18999, "lon": -118.1330, "alt_m": 30, "heading_deg": 0, "gimbal_pitch_deg": -45, "hfov_deg": 70}
```
If that module already knows which house is in view, it can skip the geometry and send `"target_parcel_id": "DEMO-0003"`, `"target_address": "2441 Cedar Ridge Dr"`, or `"target_lat"`/`"target_lon"`.

**Radar → `POST /api/radar`**. Give each detection one of three location forms: a range plus an azimuth relative to the drone's heading, a lat/lon, or a parcel_id.
```json
{"detections": [{"type": "breathing", "confidence": 0.82, "range_m": 35, "azimuth_deg": -8, "breath_rate_bpm": 14}]}
```
`python examples/fake_modules.py` sends both feeds so you can test before the real modules are ready.

**Read endpoints:** `GET /api/state` (everything the dashboard shows), `/api/property/{id}`, `/api/report`, `/api/report.csv`, `/video.mjpg`, `/frame.jpg`.

## Data

`data/parcels.json` holds **18 fictional demo properties** near Altadena, CA, including made-up policy numbers and limits. Replace them with real data in the same schema (`parcel_id, address, lat, lon, sqft, year_built, structure_type, stories, roof_type, construction, occupants_on_file, pets_on_file, policy{...}`). Good sources:
- Parcel footprints and attributes: LA County Assessor open data.
- **Real addresses plus ground truth:** CAL FIRE publishes its Damage Inspection (DINS) results as the "DINS 2025 Eaton Public View" and "DINS 2025 Palisades Public View" datasets (data.lacounty.gov / data.ca.gov). LA County also publishes a "2025 Parcels with DINS data" layer that joins those results to parcels. It uses the same 5 damage categories as this app, so you can load it as the parcel DB and score your AI calls against the inspectors'. That would make a strong slide for the judges.
- `--reverse-geocode` looks up an address from OpenStreetMap when the look point doesn't match any parcel.

## Knobs

| Flag / env | Default | Purpose |
|---|---|---|
| `--provider` | `auto` | `nemotron`, `claude`, `gemini` or `none` |
| `--model` / `DRONEEYE_MODEL` | per provider | Override the model, e.g. `claude-haiku-5-5` for faster, cheaper calls |
| `--assess-interval` | 10 s | Wait between re-assessments of the same house |
| `--max-assess-per-house` | 3 | Limits API calls per house visit |
| `DRONEEYE_COST_PER_SQFT` | 450 | Assumed rebuild cost per square foot |
| `--yolo` | `yolo11n.pt` | Weights download automatically on first run. Without ultralytics it falls back to OpenCV HOG (people only). |
| `--no-llm` | off | Offline mode |

## Honest limitations (say these before the judges do)
- The estimate is a triage number for an adjuster to review, not a coverage decision. Every assumption is in `droneeye/pricing.py`.
- Look-point geometry assumes flat ground and a correct heading. If GPS or compass error puts it more than about 45 m off, it won't match a parcel.
- The flame detector is a color heuristic, so a bright orange object can trigger it. The AI pass gives the more reliable read on active fire.
- A camera can't see people inside a structure. That's what the radar fusion is for.
