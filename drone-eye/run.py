#!/usr/bin/env python3
"""Drone-Eye: simulated drone camera -> house identification -> damage + signs-of-life for adjusters.

  python run.py --source 0                 # laptop webcam (or iPhone via Continuity Camera; try 1)
  python run.py --source phone             # open http(s)://<this-machine>/phone on your iPhone
  python run.py --source demo.mp4          # recorded footage, loops
  python run.py --source http://<ip>:8080/video   # IP-camera app or a Raspberry Pi MJPEG stream
"""
import argparse
import os

import uvicorn

from droneeye.assess import AssessmentWorker, make_assessor, pick_provider, DEFAULT_MODEL
from droneeye.camera import open_source
from droneeye.detect import LifeDetector
from droneeye.geo import ParcelDB, ReverseGeocoder
from droneeye.pipeline import Pipeline
from droneeye.server import build_app
from droneeye.state import AppState
from droneeye.telemetry import Telemetry

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="0", help="webcam index, video/image path, stream URL, or 'phone'")
    ap.add_argument("--parcels", default=os.path.join(HERE, "data", "parcels.json"))
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--provider", default="auto", choices=["auto", "nemotron", "claude", "gemini", "none"],
                    help="AI for damage assessment. auto = whichever API key is set")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="override model (defaults: nvidia/nemotron-3.5-super-vl-120b-a12b, claude-sonnet-5-5, gemini-3.8-flash)")
    ap.add_argument("--no-llm", action="store_true", help="offline heuristic only (same as --provider none)")
    ap.add_argument("--yolo", default="yolo11n.pt", help="ultralytics weights for people/animal detection")
    ap.add_argument("--assess-interval", type=float, default=None, help="seconds between re-assessments of the same house")
    ap.add_argument("--max-assess-per-house", type=int, default=None, help="automatic AI looks per home visit (0 = keep looking every --assess-interval seconds). Default 8 for Nemotron")
    ap.add_argument("--alt", type=float, default=30.0, help="simulated altitude (m)")
    ap.add_argument("--pitch", type=float, default=-45.0, help="simulated gimbal pitch (deg, -90 = straight down)")
    ap.add_argument("--disaster", default="wildfire", choices=["wildfire", "hurricane", "flood"],
                    help="disaster type to survey (can also be switched from the dashboard)")
    ap.add_argument("--keep-photos", type=int, default=30, help="automatic evidence photos kept per home (manual photos are always kept)")
    ap.add_argument("--report-to", default="Claims adjuster", help='name on the "Prepared for" line of claim PDFs')
    ap.add_argument("--report-photos", type=int, default=6, help="photos per home in claim PDFs")
    ap.add_argument("--agent", action="store_true", help="start the Nemotron survey agent right away (or use the dashboard button)")
    ap.add_argument("--agent-model", default=None, help="model for the survey agent (default: same as --model)")
    ap.add_argument("--list-cameras", action="store_true", help="list camera indexes you can pass to --source, then exit")
    ap.add_argument("--reverse-geocode", action="store_true", help="look up addresses via OpenStreetMap when no parcel matches")
    args = ap.parse_args()
    if args.list_cameras:
        from droneeye.camera import list_cameras
        list_cameras()
        return

    parcels = ParcelDB(args.parcels)
    tel = Telemetry(parcels, alt_m=args.alt, pitch=args.pitch)
    state = AppState(parcels, os.path.join(HERE, "output", "snapshots"))
    state.set_hazard(args.disaster)
    state.keep_auto = max(1, args.keep_photos)
    state.report_to = args.report_to
    state.report_photos = max(1, args.report_photos)
    source = open_source(args.source)
    detector = LifeDetector(args.yolo)
    provider = "none" if args.no_llm else pick_provider(args.provider)
    primary, fallback = make_assessor(provider, args.model)
    # Gemini's free tier allows only a small number of requests per day: assess each house once by default.
    if args.max_assess_per_house is None:
        args.max_assess_per_house = 1 if provider == "gemini" else (3 if provider == "claude" else 8)
    if args.assess_interval is None:
        args.assess_interval = 30.0 if provider == "gemini" else 10.0

    pipe = Pipeline(
        source, parcels, tel, state, detector,
        worker_factory=lambda cb: AssessmentWorker(primary, fallback, cb),
        geocoder=ReverseGeocoder(args.reverse_geocode),
        assess_interval_s=args.assess_interval, max_auto_per_visit=args.max_assess_per_house,
    )
    pipe.start()

    from droneeye.agent import NemotronPlanner, RulePlanner, SurveyAgent
    planner = RulePlanner()
    if provider == "nemotron":
        try:
            from droneeye.assess import DEFAULT_MODELS
            planner = NemotronPlanner(args.agent_model or args.model or DEFAULT_MODELS["nemotron"])
        except Exception as e:
            print(f"  [agent] Nemotron planner unavailable ({e}); using offline rules")
    agent = SurveyAgent(pipe, planner, os.path.join(HERE, "output", "reports"))
    if args.agent:
        agent.start()
    print(f"\n  Drone-Eye running: disaster={args.disaster} camera={source.describe()} detector={detector.backend} "
          f"assessor={(primary or fallback).name} agent={planner.name}")
    print(f"  Dashboard:  http://localhost:{args.port}/")
    if args.source == "phone":
        print(f"  Phone page: https://<your-https-tunnel>/phone   (see README: phones need HTTPS for the camera)")
    print()
    uvicorn.run(build_app(pipe, agent), host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
