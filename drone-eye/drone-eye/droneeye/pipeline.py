"""Main loop: frame -> which house -> detect life/fire -> schedule AI assessment -> draw HUD."""
from __future__ import annotations

import collections
import threading
import time

import cv2
import numpy as np

from .assess import AssessmentWorker
from .camera import FrameSource
from .detect import LifeDetector, detect_fire
from .geo import ParcelDB, ReverseGeocoder, look_point
from .state import AppState
from .telemetry import Telemetry
from . import pricing

CAT_COLORS = {  # BGR
    "No Damage": (80, 175, 76), "Affected (1-9%)": (59, 235, 255), "Minor (10-25%)": (0, 193, 255),
    "Major (26-50%)": (0, 112, 255), "Destroyed (>50%)": (54, 67, 244), "Unknown": (150, 150, 150),
}
KIND_COLORS = {"life": (60, 60, 255), "asset": (255, 200, 0), "fire": (0, 140, 255)}


class Pipeline:
    def __init__(self, source: FrameSource, parcels: ParcelDB, telemetry: Telemetry, state: AppState,
                 detector: LifeDetector, worker_factory, geocoder: ReverseGeocoder,
                 assess_interval_s=10.0, max_auto_per_visit=3, settle_s=0.8, life_streak=3):
        self.source = source
        self.parcels = parcels
        self.tel = telemetry
        self.state = state
        self.detector = detector
        self.geocoder = geocoder
        self.worker: AssessmentWorker = worker_factory(self.state.add_assessment)
        self.assess_interval_s = assess_interval_s
        self.max_auto = max_auto_per_visit
        self.settle_s = settle_s
        self.life_streak = life_streak

        self._jpeg = None
        self._jpeg_cv = threading.Condition()
        self._frame_no = 0
        self._raw = None
        self._force = False
        self._force_manual = False
        self._force_by = "you"
        self.auto_paused = False      # True while the survey agent decides when to look
        self._target = None
        self._target_since = 0.0
        self._visit_submits = 0
        self._last_submit = 0.0
        self._streaks = collections.Counter()
        self._survey = -1
        self._fps_t = collections.deque(maxlen=30)
        self.running = True

    # ---------- public ----------
    def force_assess(self, manual: bool = False, by: str = "you"):
        self._force = True
        self._force_manual = manual
        self._force_by = by

    def latest_jpeg(self, after_no=-1, timeout=1.0):
        with self._jpeg_cv:
            if self._frame_no <= after_no:
                self._jpeg_cv.wait(timeout)
            return self._frame_no, self._jpeg

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    # ---------- loop ----------
    def _loop(self):
        while self.running:
            frame = self.source.read()
            if frame is None:
                self._publish(self._waiting_frame())
                time.sleep(0.1)
                continue
            try:
                self._process(frame)
            except Exception as e:
                import traceback
                traceback.print_exc()
                time.sleep(0.2)

    def _process(self, frame):
        now = time.time()
        self.tel.tick()
        pose = self.tel.current()
        lat, lon = look_point(pose)
        parcel, dist = self.parcels.resolve_target(pose)
        pid = parcel["parcel_id"] if parcel else None
        address = parcel["address"] if parcel else None
        if parcel is None:
            address = self.geocoder.lookup(lat, lon)

        if pid != self._target or self._survey != self.state.survey_id:   # new house, or disaster type switched
            self._target, self._target_since, self._visit_submits = pid, now, 0
            self._survey = self.state.survey_id
            self._streaks.clear()

        # --- on-device detection ---
        dets = self.detector.detect(frame)
        from .hazards import get as get_hazard
        if get_hazard(self.state.hazard)["fire_detector"]:   # flame colours mean nothing in a flood or storm
            fire_ratio, fire_dets = detect_fire(frame)
            dets += fire_dets
        else:
            fire_ratio = 0.0

        labels_now = collections.Counter(d.label for d in dets if d.kind == "life")
        for label in list(self._streaks):
            if label not in labels_now:
                self._streaks[label] = 0
        for label, n in labels_now.items():
            self._streaks[label] += 1
            if self._streaks[label] == self.life_streak:
                conf = max(d.conf for d in dets if d.label == label)
                self.state.raise_alert(pid, "camera", f"{n} {label}{'s' if n > 1 else ''} visible", conf)

        summary = ", ".join(f"{n} {k}" for k, n in collections.Counter(d.label for d in dets).items())
        life_summary = ", ".join(f"{n} {k}" for k, n in labels_now.items())

        # --- schedule AI assessment ---
        settled = now - self._target_since >= self.settle_s
        due = (self._visit_submits == 0 or now - self._last_submit >= self.assess_interval_s)
        if self._force or (not self.auto_paused and settled and due and (self.max_auto <= 0 or self._visit_submits < self.max_auto)):
            fh, fw = frame.shape[:2]
            det_frac = [{"label": d.label, "kind": d.kind, "conf": round(d.conf, 2),
                         "box": [round(d.box[0] / fw, 4), round(d.box[1] / fh, 4), round(d.box[2] / fw, 4), round(d.box[3] / fh, 4)]}
                        for d in dets if d.kind in ("life", "fire")]
            ctx = {"manual": self._force and self._force_manual, "by": self._force_by if (self._force and self._force_manual) else "auto", "detections": det_frac, "onboard_detections": summary, "onboard_life": life_summary, "hazard": self.state.hazard, "survey_id": self.state.survey_id,
                   "radar": self.state.recent_radar_summary(pid)}
            self.worker.submit(frame.copy(), parcel, ctx)
            if not (self._force and self._force_manual):
                self._visit_submits += 1      # manual photos don't use up the automatic passes
            self._force = False
            self._force_manual = False
            self._last_submit = now

        # --- dashboard state ---
        self._fps_t.append(now)
        fps = (len(self._fps_t) - 1) / (self._fps_t[-1] - self._fps_t[0]) if len(self._fps_t) > 1 else 0
        h, w = frame.shape[:2]
        with self.state.lock:
            self.state.live = {
                "t": now, "fps": round(fps, 1), "frame_size": [w, h],
                "pose": self.tel.as_dict(),
                "look_point": {"lat": lat, "lon": lon},
                "target_parcel_id": pid, "target_address": address,
                "target_distance_m": round(dist, 1) if dist != float("inf") else None,
                "parcels_in_view": self.parcels.in_view(pose),
                "detections": [d.to_dict() for d in dets],
                "fire_ratio": round(fire_ratio, 4),
                "assessing": self.worker.busy, "assess_error": self.worker.last_error,
                "assess_calls": self.worker.calls,
                "detector": self.detector.backend, "camera": self.source.describe(),
            }
        self._publish(self._draw(frame, pose, parcel, address, dets))

    # ---------- drawing ----------
    def _draw(self, frame, pose, parcel, address, dets):
        img = frame.copy()
        h, w = img.shape[:2]
        sc = max(w / 1280, 0.5)
        font = cv2.FONT_HERSHEY_SIMPLEX
        for d in dets:
            x1, y1, x2, y2 = map(int, d.box)
            col = KIND_COLORS[d.kind]
            cv2.rectangle(img, (x1, y1), (x2, y2), col, max(2, int(2 * sc)))
            txt = f"{d.label.upper()} {d.conf:.2f}"
            cv2.putText(img, txt, (x1, max(y1 - 6, 14)), font, 0.55 * sc, col, max(1, int(2 * sc)))
        # crosshair
        cx, cy = w // 2, h // 2
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            cv2.line(img, (cx + dx * 12, cy + dy * 12), (cx + dx * 34, cy + dy * 34), (255, 255, 255), 2)

        # top bar: which house + verdict
        a = self.state.best(parcel["parcel_id"]) if parcel else None
        cat = a["damage_category"] if a else "Unknown"
        col = CAT_COLORS.get(cat, (150, 150, 150))
        bar_h = int(64 * sc)
        overlay = img.copy()
        cv2.rectangle(overlay, (0, 0), (w, bar_h), (20, 20, 20), -1)
        cv2.addWeighted(overlay, 0.65, img, 0.35, 0, img)
        cv2.rectangle(img, (0, 0), (int(10 * sc), bar_h), col, -1)
        title = address or "No parcel on file at look point"
        cv2.putText(img, title[:70], (int(20 * sc), int(26 * sc)), font, 0.7 * sc, (255, 255, 255), max(1, int(2 * sc)))
        sub = "awaiting assessment..." if not a else f"{cat}  |  {a.get('damage_percent', 0):.0f}%  |  conf {a.get('confidence', 0):.2f}"
        if a and parcel:
            est = pricing.estimate(parcel, a, self.state.hazard)
            if est and est.get("status") == "ok":
                sub += f"  |  est ${est['range_low']:,} - ${est['range_high']:,}"
        if self.worker.busy:
            sub += "  |  AI assessing..."
        cv2.putText(img, sub, (int(20 * sc), int(52 * sc)), font, 0.55 * sc, col, max(1, int(2 * sc)))

        # life banner
        if any(d.kind == "life" and d.label == "person" for d in dets):
            if int(time.time() * 3) % 2 == 0:
                cv2.rectangle(img, (0, bar_h), (w, bar_h + int(36 * sc)), (0, 0, 220), -1)
                cv2.putText(img, "SIGNS OF LIFE DETECTED", (int(20 * sc), bar_h + int(26 * sc)), font, 0.8 * sc,
                            (255, 255, 255), max(2, int(2 * sc)))

        # bottom telemetry strip
        t = f"{'LIVE' if pose.source == 'live' else 'SIM'}  {pose.lat:.6f}, {pose.lon:.6f}  ALT {pose.alt_m:.0f}m  HDG {pose.heading_deg:.0f}  PITCH {pose.gimbal_pitch_deg:.0f}"
        cv2.rectangle(img, (0, h - int(30 * sc)), (w, h), (20, 20, 20), -1)
        cv2.putText(img, t, (int(12 * sc), h - int(9 * sc)), font, 0.5 * sc, (200, 255, 200), 1)
        return img

    def _waiting_frame(self):
        img = np.zeros((480, 854, 3), np.uint8)
        cv2.putText(img, "Waiting for camera feed...", (40, 230), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
        cv2.putText(img, self.source.describe(), (40, 280), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (180, 180, 180), 1)
        return img

    def _publish(self, img):
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 75])
        if not ok:
            return
        with self._jpeg_cv:
            self._jpeg = buf.tobytes()
            self._frame_no += 1
            self._jpeg_cv.notify_all()
