"""Real-time, on-device detection that runs on every frame:
  - people and animals (signs of life) with YOLO, falling back to OpenCV's HOG person detector
  - vehicles (insured assets in the driveway)
  - visible flame via a colour heuristic
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

COCO_LIFE = {0: "person", 14: "bird", 15: "cat", 16: "dog", 17: "horse", 18: "sheep", 19: "cow"}
COCO_ASSET = {2: "car", 3: "motorcycle", 5: "bus", 7: "truck", 8: "boat"}


@dataclass
class Detection:
    label: str
    conf: float
    box: tuple  # x1, y1, x2, y2
    kind: str   # "life" | "asset" | "fire"

    def to_dict(self):
        return {"label": self.label, "conf": round(self.conf, 3), "box": [int(v) for v in self.box], "kind": self.kind}


class LifeDetector:
    def __init__(self, model_name: str = "yolo11n.pt", conf: float = 0.35, imgsz: int = 640):
        self.conf = conf
        self.imgsz = imgsz
        self.backend = "none"
        self.model = None
        try:
            from ultralytics import YOLO
            self.model = YOLO(model_name)
            self.backend = f"yolo:{model_name}"
        except Exception as e:  # ultralytics missing or weights unavailable
            print(f"[detect] YOLO unavailable ({e}); falling back to OpenCV HOG person detector")
            self.hog = cv2.HOGDescriptor()
            self.hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
            self.backend = "opencv-hog"

    def detect(self, frame: np.ndarray) -> list[Detection]:
        out: list[Detection] = []
        if self.model is not None:
            classes = list(COCO_LIFE) + list(COCO_ASSET)
            r = self.model.predict(frame, imgsz=self.imgsz, conf=self.conf, classes=classes, verbose=False)[0]
            for box, c, k in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist(), r.boxes.cls.tolist()):
                k = int(k)
                if k in COCO_LIFE:
                    out.append(Detection(COCO_LIFE[k], c, tuple(box), "life"))
                elif k in COCO_ASSET:
                    out.append(Detection(COCO_ASSET[k], c, tuple(box), "asset"))
        else:
            h, w = frame.shape[:2]
            scale = 640 / max(h, w)
            small = cv2.resize(frame, None, fx=scale, fy=scale) if scale < 1 else frame
            s = scale if scale < 1 else 1.0
            rects, weights = self.hog.detectMultiScale(small, winStride=(8, 8), padding=(8, 8), scale=1.05)
            for (x, y, bw, bh), wt in zip(rects, np.ravel(weights) if len(rects) else []):
                if wt < 0.5:
                    continue
                out.append(Detection("person", float(min(wt, 1.0)), (x / s, y / s, (x + bw) / s, (y + bh) / s), "life"))
        return out


def detect_fire(frame: np.ndarray, min_area_frac: float = 0.002):
    """Bright orange/yellow, highly saturated regions = probable open flame.
    Returns (fraction of frame that looks like flame, list of Detections)."""
    h, w = frame.shape[:2]
    small = cv2.resize(frame, (w // 2, h // 2))
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    mask = cv2.inRange(hsv, (0, 110, 200), (35, 255, 255))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    ratio = float(np.count_nonzero(mask)) / mask.size
    dets = []
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    min_area = min_area_frac * mask.size
    for c in contours:
        if cv2.contourArea(c) < min_area:
            continue
        x, y, bw, bh = cv2.boundingRect(c)
        dets.append(Detection("fire", min(1.0, cv2.contourArea(c) / (bw * bh + 1e-6)),
                              (x * 2, y * 2, (x + bw) * 2, (y + bh) * 2), "fire"))
    return ratio, dets
