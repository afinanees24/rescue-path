"""Geometry: where is the camera pointing, and which house is that?"""
from __future__ import annotations

import json
import math
import threading
import time
from dataclasses import dataclass, field
from typing import Optional

EARTH_R = 6371000.0


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(a))


def bearing_deg(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def offset(lat, lon, distance_m, heading_deg):
    """Move distance_m from (lat, lon) along heading (0 = north, 90 = east)."""
    h = math.radians(heading_deg)
    dlat = distance_m * math.cos(h) / EARTH_R
    dlon = distance_m * math.sin(h) / (EARTH_R * math.cos(math.radians(lat)))
    return lat + math.degrees(dlat), lon + math.degrees(dlon)


@dataclass
class Pose:
    """Drone pose as delivered by the location module."""
    lat: float
    lon: float
    alt_m: float = 30.0            # height above ground
    heading_deg: float = 0.0       # direction the camera faces, 0 = north
    gimbal_pitch_deg: float = -45  # 0 = horizon, -90 = straight down
    hfov_deg: float = 70.0         # horizontal field of view of the camera
    timestamp: float = field(default_factory=time.time)
    source: str = "sim"
    # Optional: the location module can tell us exactly which house it's looking at.
    target_parcel_id: Optional[str] = None
    target_address: Optional[str] = None
    target_lat: Optional[float] = None
    target_lon: Optional[float] = None


def look_point(p: Pose):
    """Where the camera's center ray hits flat ground."""
    if p.target_lat is not None and p.target_lon is not None:
        return p.target_lat, p.target_lon
    pitch = abs(p.gimbal_pitch_deg)
    if pitch >= 89.5:
        return p.lat, p.lon
    pitch = max(pitch, 5.0)  # near-horizontal would project to infinity
    ground_dist = p.alt_m / math.tan(math.radians(pitch))
    return offset(p.lat, p.lon, ground_dist, p.heading_deg)


class ParcelDB:
    def __init__(self, path: str):
        with open(path) as f:
            raw = json.load(f)
        self.center = raw.get("center")
        self.parcels = {p["parcel_id"]: p for p in raw["parcels"]}
        if not self.center and self.parcels:
            ps = list(self.parcels.values())
            self.center = {"lat": sum(p["lat"] for p in ps) / len(ps),
                           "lon": sum(p["lon"] for p in ps) / len(ps)}

    def get(self, pid):
        return self.parcels.get(pid)

    def ordered(self):
        return list(self.parcels.values())

    def by_address(self, address: str):
        a = address.strip().lower()
        for p in self.parcels.values():
            if p["address"].lower().startswith(a) or a.startswith(p["address"].lower()):
                return p
        return None

    def nearest(self, lat, lon, max_m=45.0):
        best, best_d = None, float("inf")
        for p in self.parcels.values():
            d = haversine_m(lat, lon, p["lat"], p["lon"])
            if d < best_d:
                best, best_d = p, d
        if best is None or best_d > max_m:
            return None, best_d
        return best, best_d

    def in_view(self, pose: Pose, max_range_m=150.0):
        """Parcels inside the camera's horizontal FOV cone, sorted left -> right."""
        out = []
        for p in self.parcels.values():
            d = haversine_m(pose.lat, pose.lon, p["lat"], p["lon"])
            if d > max_range_m:
                continue
            rel = (bearing_deg(pose.lat, pose.lon, p["lat"], p["lon"]) - pose.heading_deg + 540) % 360 - 180
            if abs(rel) <= pose.hfov_deg / 2:
                out.append((rel, p["parcel_id"]))
        return [pid for _, pid in sorted(out)]

    def resolve_target(self, pose: Pose):
        """Pick the house the drone is looking at. Explicit IDs from the location module win."""
        if pose.target_parcel_id and pose.target_parcel_id in self.parcels:
            return self.parcels[pose.target_parcel_id], 0.0
        if pose.target_address:
            p = self.by_address(pose.target_address)
            if p:
                return p, 0.0
        lat, lon = look_point(pose)
        return self.nearest(lat, lon)


class ReverseGeocoder:
    """Optional fallback when the look point isn't in the parcel DB (uses OpenStreetMap Nominatim;
    their policy allows ~1 request/second with a real User-Agent). Results are cached on a ~10 m grid."""

    def __init__(self, enabled=False, user_agent="drone-eye-hackutd-demo"):
        self.enabled = enabled
        self.ua = user_agent
        self.cache = {}
        self._last = 0.0
        self._lock = threading.Lock()

    def lookup(self, lat, lon) -> Optional[str]:
        if not self.enabled:
            return None
        key = (round(lat, 4), round(lon, 4))
        if key in self.cache:
            return self.cache[key]
        with self._lock:
            if time.time() - self._last < 1.1:
                return None
            self._last = time.time()
        try:
            import urllib.request
            url = (f"https://nominatim.openstreetmap.org/reverse?format=jsonv2"
                   f"&lat={lat}&lon={lon}&zoom=18&addressdetails=0")
            req = urllib.request.Request(url, headers={"User-Agent": self.ua})
            with urllib.request.urlopen(req, timeout=4) as r:
                data = json.loads(r.read())
            addr = data.get("display_name")
        except Exception:
            addr = None
        self.cache[key] = addr
        return addr
