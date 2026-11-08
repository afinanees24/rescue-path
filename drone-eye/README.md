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

```bash
pip install -r requirements.txt
export NVIDIA_API_KEY=nvapi-...            # or ANTHROPIC_API_KEY / GEMINI_API_KEY; with none, a crude offline heuristic
python run.py --source 0                   # webcam
# open http://localhost:8000
```
Windows PowerShell: activate with `.venv\Scripts\Activate.ps1` and set the key with `$env:NVIDIA_API_KEY="nvapi-..."`.

### Choosing the AI
| Provider | Key | Default model | Notes |
|---|---|---|---|
| `nemotron` | `NVIDIA_API_KEY` (build.nvidia.com) | `nvidia/nemotron-3.5-super-vl-120b-a12b` | NVIDIA's hosted API. Set `NVIDIA_BASE_URL` to use a local NIM instead. |
| `claude` | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5` | Most reliable structured output |
| `gemini` | `GEMINI_API_KEY` | `gemini-3.8-flash` | The free tier has a low daily request cap, so by default each house is assessed only once |

`--provider auto` (the default) uses whichever key is set. If more than one is set, it picks NVIDIA, then Claude, then Gemini. Force a choice with `--provider nemotron`. If the AI call fails (bad key, rate limit, no Wi-Fi), that frame falls back to the offline heuristic and the dashboard shows an "AI error" chip.

Use the dashboard's **Prev / Next house**, **Auto-tour** and map clicks to "fly" the simulated drone until the real location module is connected. **Assess now** forces a fresh AI pass. **Export claims CSV** gives the adjuster's worklist.

## Evidence photos

Every time the AI rates a home, the exact camera frame is saved, and the AI marks where the damage is (roof, walls, windows…) with boxes. The dashboard's **What the AI saw** panel shows the photo with those boxes plus the detector's person and fire boxes. Hover a finding to highlight its box, and click a thumbnail to see an earlier photo. **Open marked photo** gives a copy with the boxes burned in, for the claim file.

**Take your own photo:** click **Take photo** (or press **P**) when the drone has a good angle. The current frame is sent to the AI right away; it shows up with a lime dot in the thumbnail strip and doesn't use up the automatic looks.

| Setting | Default | What it does |
|---|---|---|
| `--max-assess-per-house N` | 8 (Nemotron) | Automatic AI looks each time the drone arrives at a home. `0` = keep looking every `--assess-interval` seconds |
| `--assess-interval S` | 10 | Seconds between automatic looks at the same home |
| `--keep-photos N` | 30 | Automatic photos kept per home (oldest deleted first). Photos you take are always kept |

Photos are saved in `output/snapshots/`.

## AI survey agent (Nemotron)

Press **Start agent** on the dashboard (or run with `--agent`). Nemotron 3.5 Super VL then runs the survey home by home, choosing its own next step with tool calls:

| Tool | What it does |
|---|---|
| `look_at_home` | Captures the drone frame and has Nemotron's vision rate the damage |
| `request_new_angle` | Asks the pilot for a better view when the rating is Unknown or unsure, then looks again |
| `lookup_property` / `check_for_people` | Occupants and pets on file, coverage, and signs of life from the camera, detector and radar |
| `raise_alert` | Alerts responders, e.g. "3 people live here, home destroyed, nobody confirmed safe" |
| `estimate_payout` / `file_claim_report` | Prices the claim and writes the claim PDF to `output/reports/` |
| `survey_status` / `next_home` | Reads the priority list and picks the most urgent home not yet surveyed (in sim mode it flies there; with a real drone it tells the pilot) |

Every thought, tool call and result shows up live in the **AI survey agent** panel. While the agent runs, automatic looks pause so it decides when to look. Without an NVIDIA key, the same tools run on fixed rules ("offline rules"), so the demo still works.

How it uses the API: OpenAI-style `tools` with `tool_choice: "auto"` and `reasoning_effort: "low"`, so a short reasoning trace shows in the log. If the endpoint refuses tool calls, the agent switches to JSON actions automatically. Damage ratings use `response_format: json_schema`, which NVIDIA's docs recommend so every required field comes back.

## Who needs help first

The **Who needs help first** panel ranks every home so no one is overlooked:
1. People seen (camera, onboard detector or radar)
2. Occupants on file, home Major or Destroyed, nobody confirmed safe
3. Unsafe site (fire, collapse, power lines, deep water)
4. Uninsured loss
5. Damaged
6. No damage

Below the list are the homes not checked yet. Click a home to fly there. Pressing **Handled** on an alert marks those occupants as confirmed safe. The same ranking is at `/api/priorities`.

## Claim report (PDF)

Click **Claim PDF ↓** under the 3D house (or **Download claim report** in "What the AI saw") to get a PDF for the home in view. It has:

- property and policy details
- the AI's damage rating for each part of the home
- the payout breakdown (rebuild, garage and fence, belongings, debris, deductible, net, likely range)
- hazards and signs of life
- the marked photos, with time, rating and findings for each
- a sign-off line for the reviewing adjuster

The download icon in the top bar gives one PDF for every rated home (shift-click it for the CSV spreadsheet).

| Setting | Default | What it does |
|---|---|---|
| `--report-to "State Farm Claims"` | Claims adjuster | Name on the "Prepared for" line |
| `--report-photos N` | 6 | Photos per home in the PDF (the rated photo first, then ones you took, then the newest automatic) |

Endpoints: `/api/property/{parcel_id}/claim.pdf`, `/api/claims.pdf`. The report is labeled as a preliminary AI-assisted estimate for adjuster review, not a coverage decision.

## Disaster types

Pick one with `--disaster wildfire|hurricane|flood`, or switch from the **Disaster** menu on the dashboard. Switching starts a new survey.

| | What the AI looks for | How the claim is priced | 3D house shows |
|---|---|---|---|
| **Wildfire** | Burned/charred parts, active fire, smoke | Homeowners policy | Scorching, roof caving in, walls burning down, flames, smoke, embers |
| **Hurricane / wind** | Missing shingles, tarps, roof torn off, trees on the house, broken windows | Homeowners policy with a 2% hurricane deductible, plus tree removal | Missing shingles, blue tarp, roof lifting or blown away, walls falling outward, trees blown over, debris |
| **Flood** | How high the water reached (`water_depth_ft`), from waterlines, doors, cars | **Flood policy only.** Homeowners policies exclude flood, so a home without a flood policy shows its loss as **uninsured** | Muddy water at the estimated height, waterline stain, car under water |

About 40% of the demo homes carry a demo flood policy (`flood_policy` in `data/parcels.json`). Every number in the pricing is a labeled assumption in `droneeye/pricing.py`. Add a new disaster type in `droneeye/hazards.py`.

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
