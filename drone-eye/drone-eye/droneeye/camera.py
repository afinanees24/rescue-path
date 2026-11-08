"""Frame sources that stand in for the drone's camera.

Supported --source values:
  0, 1, 2 ...          local webcam index (iPhone via macOS Continuity Camera shows up here too)
  path/to/video.mp4    a recorded flight / any video file (loops)
  path/to/image.jpg    a single still image (repeated as a "feed")
  http://... rtsp://.. an MJPEG/RTSP stream (IP Webcam apps, a Raspberry Pi streaming rpicam-vid, etc.)
  phone                frames pushed from the /phone page in a phone's browser
"""
from __future__ import annotations

import os
import threading
import time
from typing import Optional

import cv2
import numpy as np


class FrameSource:
    def read(self) -> Optional[np.ndarray]:
        raise NotImplementedError

    def describe(self) -> str:
        return self.__class__.__name__

    def close(self) -> None:
        pass


class OpenCVSource(FrameSource):
    """Webcam index, video file, or network stream, read on a background thread
    so the pipeline always gets the newest frame instead of a stale buffered one."""

    def __init__(self, spec: str, width: int = 1280, height: int = 720):
        self.spec = spec
        self.is_file = os.path.isfile(spec)
        self.size = (width, height)
        self.cap = _open_capture(spec, width, height)
        if self.cap is None:
            raise RuntimeError(f"Could not open video source: {spec!r}  (run: python run.py --list-cameras)")
        fps = self.cap.get(cv2.CAP_PROP_FPS)
        self.file_delay = 1.0 / fps if (self.is_file and fps and fps > 0) else 0.0
        self._frame: Optional[np.ndarray] = None
        self._lock = threading.Lock()
        self._running = True
        self._t = threading.Thread(target=self._loop, daemon=True)
        self._t.start()

    def _loop(self):
        failures = 0
        while self._running:
            try:
                ok, frame = self.cap.read()
            except cv2.error as e:
                ok, frame = False, None
                if failures == 0:
                    print(f"[camera] read error ({str(e).strip().splitlines()[-1][:80]}); retrying")
            if ok and frame is not None:
                failures = 0
            else:
                failures += 1
                if failures >= 30 and not self.is_file:  # ~1.5 s of bad reads: reopen the device
                    print("[camera] reopening video source")
                    try:
                        self.cap.release()
                    except Exception:
                        pass
                    cap = _open_capture(self.spec, *self.size)
                    if cap is not None:
                        self.cap = cap
                    failures = 0
            if not ok or frame is None:
                if self.is_file:  # loop recorded footage
                    self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    continue
                time.sleep(0.05)
                continue
            with self._lock:
                self._frame = frame
            if self.file_delay:
                time.sleep(self.file_delay)

    def read(self):
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def describe(self):
        return f"opencv:{self.spec}"

    def close(self):
        self._running = False
        self.cap.release()


class ImageSource(FrameSource):
    def __init__(self, path: str):
        img = cv2.imread(path)
        if img is None:
            raise RuntimeError(f"Could not read image {path!r}")
        self.img = img
        self.path = path

    def read(self):
        time.sleep(0.03)
        return self.img.copy()

    def describe(self):
        return f"image:{self.path}"


class PushSource(FrameSource):
    """Frames are pushed in (from the phone page websocket, or any other uplink)."""

    def __init__(self):
        self._frame: Optional[np.ndarray] = None
        self._lock = threading.Lock()
        self.last_push = 0.0

    def push_jpeg(self, data: bytes) -> bool:
        arr = np.frombuffer(data, dtype=np.uint8)
        frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if frame is None:
            return False
        with self._lock:
            self._frame = frame
            self.last_push = time.time()
        return True

    def read(self):
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def describe(self):
        live = time.time() - self.last_push < 2
        return f"phone ({'live' if live else 'waiting for /phone page'})"


def _camera_index(spec: str):
    """'1' -> 1, 'dshow:1' -> 1, anything else -> None."""
    tail = spec.split(":", 1)[1] if spec.lower().startswith("dshow:") else spec
    return int(tail) if tail.isdigit() else None


def _safe_read(cap):
    try:
        ok, frame = cap.read()
        return bool(ok) and frame is not None
    except cv2.error:
        return False


def _open_capture(spec: str, width: int = 1280, height: int = 720):
    """Open a webcam index, file or URL. On Windows, try DirectShow first: it sees virtual cameras
    (OBS, Camo, iVCam) and doesn't hit the Media Foundation resize bug ('_step >= minstep')."""
    idx = _camera_index(spec)
    if idx is None:
        cap = cv2.VideoCapture(spec)
        return cap if cap.isOpened() else None
    if spec.lower().startswith("dshow:"):
        backends = [cv2.CAP_DSHOW]
    elif os.name == "nt":
        backends = [cv2.CAP_DSHOW, cv2.CAP_MSMF, cv2.CAP_ANY]
    else:
        backends = [cv2.CAP_ANY]
    for be in backends:
        for want_size in (True, False):  # some drivers break when asked for a size: retry at native size
            cap = cv2.VideoCapture(idx, be)
            if not cap.isOpened():
                cap.release()
                break
            if want_size:
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            if all(_safe_read(cap) for _ in range(3)):
                return cap
            cap.release()
    return None


def list_cameras(max_index: int = 8):
    """Print every camera index that delivers frames, per backend (helps find OBS Virtual Camera)."""
    try:
        cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_SILENT)
    except Exception:
        pass
    names = [("default", cv2.CAP_ANY)] + ([("dshow", cv2.CAP_DSHOW)] if os.name == "nt" else [])
    found = False
    for label, be in names:
        for i in range(max_index):
            cap = cv2.VideoCapture(i, be)
            ok = cap.isOpened() and cap.read()[0]
            if ok:
                w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
                spec = str(i) if label == "default" else f"dshow:{i}"
                print(f"  --source {spec:<8} works  ({w}x{h}, {label} backend)")
                found = True
            cap.release()
    if not found:
        print("  No cameras found. Is OBS Virtual Camera started / the webcam free?")


IMAGE_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def open_source(spec: str) -> FrameSource:
    if spec == "phone":
        return PushSource()
    if os.path.isfile(spec) and os.path.splitext(spec)[1].lower() in IMAGE_EXT:
        return ImageSource(spec)
    return OpenCVSource(spec)
