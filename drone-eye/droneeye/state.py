"""Shared state: per-house assessments, signs-of-life alerts, radar fusion."""
from __future__ import annotations

import itertools
import math
import os
import threading
import time

import cv2

from .geo import ParcelDB, Pose, offset
from . import pricing

ALERT_MERGE_S = 120.0
_ids = itertools.count(1)


class AppState:
    def __init__(self, parcels: ParcelDB, snapshot_dir: str):
        self.parcels = parcels
        self.snapshot_dir = snapshot_dir
        os.makedirs(snapshot_dir, exist_ok=True)
        self.lock = threading.RLock()
        self.assessments: dict[str, list[dict]] = {}   # parcel_id -> history
        self.alerts: list[dict] = []
        self.live: dict = {}                           # per-frame info for the dashboard
        self.radar_hits: list[dict] = []

    # ---------- assessments ----------
    def add_assessment(self, parcel_id, result, frame):
        if parcel_id is None:
            with self.lock:
                self.live["unmatched_assessment"] = result
            return
        with self.lock:
            hist = self.assessments.setdefault(parcel_id, [])
            hist.append(result)
            del hist[:-10]
            best = self.best(parcel_id)
            if best is result:  # keep the frame that produced the best assessment as evidence
                cv2.imwrite(os.path.join(self.snapshot_dir, f"{parcel_id}.jpg"), frame)
                result["_snapshot"] = f"/snapshots/{parcel_id}.jpg"
        for sign in result.get("signs_of_life") or []:
            self.raise_alert(parcel_id, "ai", sign, result.get("confidence", 0.5))
        if result.get("active_fire"):
            self.raise_alert(parcel_id, "ai", "active fire on structure", result.get("confidence", 0.5), kind="fire")

    def best(self, parcel_id):
        """The assessment to show: the NEWEST real rating (the scene changes as the drone/video moves).
        Order of preference: AI with an actual damage category > AI 'Unknown' > offline heuristic."""
        hist = self.assessments.get(parcel_id) or []
        if not hist:
            return None
        ai = [r for r in hist if not r.get("_engine", "").startswith("offline")]
        known = [r for r in ai if r.get("damage_category") not in (None, "Unknown")]
        pool = known or ai or hist
        return max(pool, key=lambda r: r.get("_timestamp", 0))

    def property_view(self, parcel_id):
        p = self.parcels.get(parcel_id)
        if not p:
            return None
        a = self.best(parcel_id)
        return {
            "parcel": p,
            "assessment": a,
            "estimate": pricing.estimate(p, a) if a else None,
            "n_assessments": len(self.assessments.get(parcel_id, [])),
            "alerts": [x for x in self.alerts if x["parcel_id"] == parcel_id],
        }

    # ---------- signs of life ----------
    def raise_alert(self, parcel_id, source, label, conf, lat=None, lon=None, kind="life", extra=None, key=None):
        """One alert per (home, source, key): repeated sightings update it instead of stacking duplicates.
        Merges for 2 minutes unless someone marked it handled."""
        now = time.time()
        p = self.parcels.get(parcel_id) if parcel_id else None
        key = key or f"{kind}:{source}"
        with self.lock:
            for a in self.alerts:
                if (a["parcel_id"], a["source"], a.get("key")) == (parcel_id, source, key) and not a["acknowledged"] \
                        and now - a["last_seen"] < ALERT_MERGE_S:
                    a["last_seen"] = now
                    a["count"] += 1
                    a["label"] = label
                    a["confidence"] = max(a["confidence"], conf)
                    return a
            a = {
                "id": next(_ids), "kind": kind, "parcel_id": parcel_id,
                "address": p["address"] if p else None,
                "occupants_on_file": p.get("occupants_on_file") if p else None,
                "pets_on_file": p.get("pets_on_file") if p else None,
                "source": source, "key": key, "label": label, "confidence": round(float(conf), 2),
                "lat": lat if lat is not None else (p["lat"] if p else None),
                "lon": lon if lon is not None else (p["lon"] if p else None),
                "first_seen": now, "last_seen": now, "count": 1, "acknowledged": False,
                **(extra or {}),
            }
            self.alerts.append(a)
            del self.alerts[:-200]
            return a

    def ack(self, alert_id):
        with self.lock:
            for a in self.alerts:
                if a["id"] == alert_id:
                    a["acknowledged"] = True
                    return True
        return False

    # ---------- radar ----------
    def ingest_radar(self, payload: dict, pose: Pose, current_parcel_id):
        """Accepts detections with any of: parcel_id | lat/lon | range_m + azimuth_deg (relative to drone heading)."""
        out = []
        for d in payload.get("detections", []):
            label = d.get("type", "presence")
            if d.get("breath_rate_bpm"):
                label += f" ({d['breath_rate_bpm']:.0f} breaths/min)"
            if d.get("heart_rate_bpm"):
                label += f" ({d['heart_rate_bpm']:.0f} bpm)"
            conf = float(d.get("confidence", 0.7))
            lat, lon = d.get("lat"), d.get("lon")
            if lat is None and "range_m" in d:
                rng = float(d["range_m"])
                ground = math.sqrt(max(rng ** 2 - pose.alt_m ** 2, 0)) if rng > pose.alt_m else 0.0
                lat, lon = offset(pose.lat, pose.lon, ground, pose.heading_deg + float(d.get("azimuth_deg", 0)))
            pid = d.get("parcel_id")
            if pid is None and lat is not None:
                p, _ = self.parcels.nearest(lat, lon, max_m=30)
                pid = p["parcel_id"] if p else None
            if pid is None:
                pid = current_parcel_id
            hit = {"t": time.time(), "parcel_id": pid, "lat": lat, "lon": lon, "label": label, "confidence": conf}
            with self.lock:
                self.radar_hits.append(hit)
                del self.radar_hits[:-100]
            out.append(self.raise_alert(pid, "radar", label, conf, lat, lon))
        return out

    def recent_radar_summary(self, parcel_id, window_s=15):
        now = time.time()
        with self.lock:
            hits = [h for h in self.radar_hits if h["parcel_id"] == parcel_id and now - h["t"] < window_s]
        return ", ".join(sorted({h["label"] for h in hits}))
