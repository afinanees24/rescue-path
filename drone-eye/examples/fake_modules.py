#!/usr/bin/env python3
"""Stand-in for the location + radar modules, to test integration before they're ready.

  python examples/fake_modules.py                 # fly down Cedar Ridge Dr, occasional radar hits
  python examples/fake_modules.py --server http://192.168.1.20:8000

Shows the exact JSON the real modules should POST.
"""
import argparse
import json
import random
import time
import urllib.request


def post(server, path, body):
    req = urllib.request.Request(server + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=3) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://localhost:8000")
    ap.add_argument("--hz", type=float, default=2.0)
    args = ap.parse_args()

    # Drone flies east along the street, 21 m south of the house row, camera facing north and 45 deg down
    lat, lon = 34.18999, -118.13320
    while True:
        lon += 0.00002  # ~1.8 m per tick
        if lon > -118.13140:
            lon = -118.13320
        pose = {"lat": lat, "lon": lon, "alt_m": 30, "heading_deg": 0, "gimbal_pitch_deg": -55}
        r = post(args.server, "/api/telemetry", pose)
        print("telemetry ->", r.get("resolved_parcel_id"), r.get("address"))

        if random.random() < 0.05:
            hit = {"detections": [{"type": random.choice(["breathing", "motion"]), "confidence": round(random.uniform(0.6, 0.95), 2),
                                   "range_m": 38, "azimuth_deg": random.uniform(-10, 10), "breath_rate_bpm": 15}]}
            print("radar     ->", post(args.server, "/api/radar", hit))
        time.sleep(1 / args.hz)


if __name__ == "__main__":
    main()
