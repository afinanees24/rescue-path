"""HTTP API + adjuster dashboard."""
from __future__ import annotations

import csv
import io
import os
import time

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

from .camera import PushSource
from .pipeline import Pipeline

STATIC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "static")


def build_app(pipe: Pipeline, agent=None) -> FastAPI:
    app = FastAPI(title="Drone-Eye: wildfire property assessment")
    state, tel, parcels = pipe.state, pipe.tel, pipe.parcels
    app.mount("/snapshots", StaticFiles(directory=state.snapshot_dir), name="snapshots")
    reports = os.path.join(os.path.dirname(state.snapshot_dir), "reports")
    os.makedirs(reports, exist_ok=True)
    app.mount("/reports", StaticFiles(directory=reports), name="reports")
    app.mount("/static", StaticFiles(directory=STATIC), name="static")

    # ---------- pages ----------
    @app.get("/")
    def index():
        return FileResponse(os.path.join(STATIC, "index.html"))

    @app.get("/classic")
    def classic():
        return FileResponse(os.path.join(STATIC, "classic.html"))

    @app.get("/phone")
    def phone():
        return FileResponse(os.path.join(STATIC, "phone.html"))

    # ---------- video ----------
    @app.get("/video.mjpg")
    def video():
        def gen():
            last = -1
            while True:
                last, jpg = pipe.latest_jpeg(last)
                if jpg:
                    yield b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(jpg)).encode() + b"\r\n\r\n" + jpg + b"\r\n"
        return StreamingResponse(gen(), media_type="multipart/x-mixed-replace; boundary=frame")

    @app.get("/frame.jpg")
    def frame():
        _, jpg = pipe.latest_jpeg()
        return Response(jpg or b"", media_type="image/jpeg")

    @app.websocket("/ws/phone")
    async def phone_ingest(ws: WebSocket):
        await ws.accept()
        if not isinstance(pipe.source, PushSource):
            await ws.send_text("server not started with --source phone")
            await ws.close()
            return
        try:
            while True:
                data = await ws.receive_bytes()
                pipe.source.push_jpeg(data)
        except WebSocketDisconnect:
            pass

    # ---------- state for dashboard ----------
    @app.get("/api/state")
    def api_state():
        with state.lock:
            live = dict(state.live)
            alerts = sorted(state.alerts, key=lambda a: -a["last_seen"])[:50]
            summary = {}
            for pid in parcels.parcels:
                b = state.best(pid)
                summary[pid] = b["damage_category"] if b else None
        pid = live.get("target_parcel_id")
        from .hazards import get as get_hazard, options
        return {
            "live": live,
            "hazard": {"type": state.hazard, "label": get_hazard(state.hazard)["label"], "options": options(),
                       "survey_id": state.survey_id},
            "current": state.property_view(pid) if pid else None,
            "alerts": alerts,
            "parcel_status": summary,
            "unmatched_assessment": live.get("unmatched_assessment"),
            "agent": agent.view(40) if agent else None,
            "priorities": _prio_short(),
        }

    def _prio_short():
        from .triage import rank
        r = rank(state)
        return {"homes": r["homes"][:8], "unchecked": len(r["unchecked"]), "checked": r["checked"],
                "total": r["total"], "counts": r["counts"],
                "unchecked_ids": [u["parcel_id"] for u in r["unchecked"]]}

    @app.get("/api/priorities")
    def priorities():
        from .triage import rank
        return rank(state)

    @app.get("/api/agent")
    def agent_view():
        return agent.view(300) if agent else {"running": False, "log": []}

    @app.post("/api/agent/start")
    def agent_start():
        if not agent:
            return JSONResponse({"ok": False, "error": "agent not available"}, status_code=400)
        agent.start()
        return {"ok": True}

    @app.post("/api/agent/stop")
    def agent_stop():
        if agent:
            agent.stop()
        return {"ok": True}

    @app.get("/api/debug/ai")
    def debug_ai():
        """What the AI last said, raw and after cleanup. Open in a browser when ratings look wrong."""
        w = pipe.worker
        return {"engine": (w.primary or w.fallback).name, "busy": w.busy, "calls": w.calls,
                "last_error": w.last_error, "last_raw_reply": (w.last_raw or "")[:6000], "last_result": w.last_result}

    @app.get("/api/debug/ai/frame.jpg")
    def debug_ai_frame():
        """The exact image last sent to the AI, downscaled the same way."""
        import cv2
        from .assess import _downscale
        f = pipe.worker.last_frame
        if f is None:
            return Response(b"", status_code=404)
        ok, buf = cv2.imencode(".jpg", _downscale(f), [cv2.IMWRITE_JPEG_QUALITY, 85])
        return Response(buf.tobytes(), media_type="image/jpeg")

    @app.get("/api/parcels")
    def api_parcels():
        return {"center": parcels.center, "parcels": parcels.ordered()}

    @app.get("/api/property/{parcel_id}")
    def api_property(parcel_id: str):
        v = state.property_view(parcel_id)
        return v or JSONResponse({"error": "unknown parcel"}, 404)

    # ---------- inputs from other modules ----------
    @app.post("/api/telemetry")
    async def api_telemetry(req: Request):
        """From the location module. Any subset of:
        lat, lon, alt_m, heading_deg, gimbal_pitch_deg, hfov_deg,
        target_parcel_id | target_address | target_lat+target_lon (if it already knows the house)."""
        data = await req.json()
        pose = tel.update_live(data)
        p, d = parcels.resolve_target(pose)
        return {"ok": True, "resolved_parcel_id": p["parcel_id"] if p else None,
                "address": p["address"] if p else None, "distance_m": None if p is None else round(d, 1)}

    @app.post("/api/radar")
    async def api_radar(req: Request):
        """From the radar module: {"detections": [{"type": "breathing", "confidence": 0.8,
        "range_m": 12, "azimuth_deg": -10} | {"lat":..,"lon":..} | {"parcel_id": ..}]}"""
        data = await req.json()
        alerts = state.ingest_radar(data, tel.current(), state.live.get("target_parcel_id"))
        return {"ok": True, "alerts": [a["id"] for a in alerts]}

    # ---------- controls ----------
    @app.post("/api/disaster")
    async def set_disaster(req: Request):
        """Switch disaster type: {"type": "wildfire" | "hurricane" | "flood"}. Starts a new survey."""
        data = await req.json()
        try:
            state.set_hazard(data.get("type", ""))
        except ValueError as e:
            return JSONResponse({"ok": False, "error": str(e)}, 400)
        print(f"[survey] disaster type set to {state.hazard}: new survey started")
        return {"ok": True, "type": state.hazard}

    @app.post("/api/capture")
    def capture():
        """Take a photo from the drone feed right now and have the AI rate it (kept permanently)."""
        pipe.force_assess(manual=True)
        return {"ok": True}

    @app.post("/api/assess_now")
    def assess_now():
        pipe.force_assess()
        return {"ok": True}

    @app.post("/api/alerts/{alert_id}/ack")
    def ack(alert_id: int):
        return {"ok": state.ack(alert_id)}

    @app.post("/api/sim/goto/{parcel_id}")
    def sim_goto(parcel_id: str):
        return {"ok": tel.sim_goto(parcel_id)}

    @app.post("/api/sim/step/{delta}")
    def sim_step(delta: int):
        return {"ok": True, "parcel_id": tel.sim_step(delta)}

    @app.post("/api/sim/tour")
    async def sim_tour(req: Request):
        data = await req.json()
        tel.set_tour(bool(data.get("on")), data.get("dwell_s"))
        return {"ok": True, "tour_on": tel.tour_on}

    # ---------- reports ----------
    @app.get("/api/report")
    def report():
        return {"generated_at": time.time(),
                "properties": [state.property_view(pid) for pid in parcels.parcels if state.best(pid)],
                "alerts": state.alerts}

    def _pdf(pids, name):
        from .claim_pdf import build_claim_pdf
        data = build_claim_pdf(state, pids, prepared_for=getattr(state, "report_to", "Claims adjuster"),
                               photo_limit=getattr(state, "report_photos", 6))
        if not data:
            return Response("No AI rating for this home yet. Point the drone at it or press Take photo first.",
                            status_code=404, media_type="text/plain")
        return Response(data, media_type="application/pdf",
                        headers={"Content-Disposition": f'attachment; filename="{name}"'})

    @app.get("/api/property/{parcel_id}/claim.pdf")
    def claim_pdf(parcel_id: str):
        p = parcels.get(parcel_id)
        if not p:
            return Response("Unknown home", status_code=404, media_type="text/plain")
        slug = "".join(ch if ch.isalnum() else "_" for ch in p["address"].split(",")[0]).strip("_")
        return _pdf([parcel_id], f"Drone-Eye_claim_{slug}_{time.strftime('%Y%m%d-%H%M')}.pdf")

    @app.get("/api/claims.pdf")
    def claims_pdf():
        return _pdf(list(parcels.parcels), f"Drone-Eye_survey_{time.strftime('%Y%m%d-%H%M')}.pdf")

    @app.get("/api/report.csv")
    def report_csv():
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["parcel_id", "address", "policy_number", "damage_category", "damage_percent", "confidence",
                    "active_fire", "hazards", "signs_of_life", "est_net", "est_low", "est_high", "summary", "engine", "snapshot"])
        for pid in parcels.parcels:
            v = state.property_view(pid)
            a = v and v["assessment"]
            if not a:
                continue
            e = v["estimate"] or {}
            w.writerow([pid, v["parcel"]["address"], (v["parcel"].get("policy") or {}).get("policy_number"),
                        a.get("damage_category"), a.get("damage_percent"), a.get("confidence"), a.get("active_fire"),
                        "; ".join(a.get("hazards") or []), "; ".join(a.get("signs_of_life") or []),
                        e.get("net_estimate"), e.get("range_low"), e.get("range_high"),
                        a.get("adjuster_summary"), a.get("_engine"), a.get("_snapshot")])
        return Response(buf.getvalue(), media_type="text/csv",
                        headers={"Content-Disposition": "attachment; filename=drone_eye_claims.csv"})

    return app
