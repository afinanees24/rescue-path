"""Drone pose state. The location module POSTs real poses; until it does (or if it goes quiet),
a simulator 'flies' the drone so the demo still works."""
from __future__ import annotations

import threading
import time
from dataclasses import asdict, replace

from .geo import Pose, ParcelDB, offset

import os

# After this long without a POST from the location module we fall back to the simulator.
LIVE_TIMEOUT_S = float(os.environ.get("DRONEEYE_LIVE_TIMEOUT", "15"))


class Telemetry:
    def __init__(self, parcels: ParcelDB, alt_m=30.0, pitch=-45.0, standoff_heading=0.0):
        self.parcels = parcels
        self._lock = threading.Lock()
        self._live: Pose | None = None
        self.alt_m = alt_m
        self.pitch = pitch
        self.standoff_heading = standoff_heading  # camera faces this way when sim hovers
        self._sim = Pose(lat=parcels.center["lat"], lon=parcels.center["lon"], alt_m=alt_m,
                         heading_deg=standoff_heading, gimbal_pitch_deg=pitch, source="sim")
        order = parcels.ordered()
        self._tour_ids = [p["parcel_id"] for p in order]
        self._tour_idx = 0
        self.tour_on = False
        self.tour_dwell_s = 8.0
        self._tour_next = 0.0
        if order:
            self.sim_goto(order[0]["parcel_id"])

    # ---- live input from the location module ----
    def update_live(self, data: dict) -> Pose:
        base = self._live or self._sim
        fields = {k: v for k, v in data.items() if k in Pose.__dataclass_fields__}
        pose = replace(base, **fields)
        pose = replace(pose, timestamp=time.time(), source="live")
        # explicit target is per-message; don't let a stale one stick around
        for k in ("target_parcel_id", "target_address", "target_lat", "target_lon"):
            if k not in data:
                pose = replace(pose, **{k: None})
        with self._lock:
            self._live = pose
        return pose

    # ---- simulator ----
    def sim_goto(self, parcel_id: str) -> bool:
        p = self.parcels.get(parcel_id)
        if not p:
            return False
        import math
        ground = self.alt_m / math.tan(math.radians(abs(self.pitch)))
        # hover 'ground' metres back from the house so the camera's center ray lands on it
        lat, lon = offset(p["lat"], p["lon"], ground, (self.standoff_heading + 180) % 360)
        with self._lock:
            self._sim = Pose(lat=lat, lon=lon, alt_m=self.alt_m, heading_deg=self.standoff_heading,
                             gimbal_pitch_deg=self.pitch, source="sim")
            if parcel_id in self._tour_ids:
                self._tour_idx = self._tour_ids.index(parcel_id)
        return True

    def sim_step(self, delta: int):
        if not self._tour_ids:
            return None
        idx = (self._tour_idx + delta) % len(self._tour_ids)
        pid = self._tour_ids[idx]
        self.sim_goto(pid)
        return pid

    def set_tour(self, on: bool, dwell_s: float | None = None):
        self.tour_on = on
        if dwell_s:
            self.tour_dwell_s = dwell_s
        self._tour_next = time.time() + self.tour_dwell_s

    def tick(self):
        if self.tour_on and time.time() >= self._tour_next:
            self.sim_step(+1)
            self._tour_next = time.time() + self.tour_dwell_s

    # ---- read ----
    def current(self) -> Pose:
        with self._lock:
            if self._live and time.time() - self._live.timestamp < LIVE_TIMEOUT_S:
                return self._live
            return self._sim

    def as_dict(self):
        d = asdict(self.current())
        d["live"] = d["source"] == "live"
        d["tour_on"] = self.tour_on
        return d
