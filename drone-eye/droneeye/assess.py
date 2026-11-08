"""Damage assessment of the house in view.

Primary: a Claude vision model returns a structured, adjuster-style assessment (via forced tool use,
so the output is always valid JSON). Runs on a background worker a few times per house, never blocking video.
Fallback: a crude colour heuristic so the demo keeps working with no API key / no Wi-Fi.
"""
from __future__ import annotations

import base64
import os
import threading
import time
import traceback
from typing import Callable

import cv2
import numpy as np

from .detect import detect_fire

DEFAULT_MODELS = {"claude": "claude-sonnet-5-5", "gemini": "gemini-3.8-flash",
                  "nemotron": "nvidia/nemotron-3.5-super-vl-120b-a12b"}
DEFAULT_MODEL = os.environ.get("DRONEEYE_MODEL")  # None -> per-provider default above

DAMAGE_CATS = ["No Damage", "Affected (1-9%)", "Minor (10-25%)", "Major (26-50%)", "Destroyed (>50%)", "Unknown"]
COMP_LEVELS = ["none", "minor", "moderate", "severe", "destroyed", "not_visible"]
COMPONENTS = ["roof", "exterior_walls", "windows_doors", "structural_frame", "garage_outbuildings",
              "fences_walls", "vehicles", "landscaping_vegetation"]

ASSESS_TOOL = {
    "name": "record_damage_assessment",
    "description": "Record a structured property damage assessment for an insurance adjuster.",
    "input_schema": {
        "type": "object",
        "properties": {
            "structure_visible": {"type": "boolean", "description": "Is a building clearly visible?"},
            "damage_category": {"type": "string", "enum": DAMAGE_CATS,
                                "description": "CAL FIRE DINS category for the primary structure (center of frame)."},
            "damage_percent": {"type": "number", "minimum": 0, "maximum": 100,
                               "description": "Estimated % of the primary structure's value destroyed."},
            "active_fire": {"type": "boolean"},
            "smoke_present": {"type": "boolean"},
            "components": {
                "type": "object",
                "properties": {c: {"type": "string", "enum": COMP_LEVELS} for c in COMPONENTS},
                "required": COMPONENTS,
            },
            "hazards": {"type": "array", "items": {"type": "string"},
                        "description": "Safety hazards for responders/adjusters, e.g. downed power lines, collapse risk, propane tank, pool with debris."},
            "signs_of_life": {"type": "array", "items": {"type": "string"},
                              "description": "Any people, animals, movement, waving, vehicles with occupants. Empty if none."},
            "other_structures_in_frame": {"type": "array", "items": {"type": "string"},
                                          "description": "Short notes on neighbouring structures visible, left to right."},
            "adjuster_summary": {"type": "string", "description": "2-4 sentence summary in an adjuster's voice."},
            "recommended_actions": {"type": "array", "items": {"type": "string"}},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        },
        "required": ["structure_visible", "damage_category", "damage_percent", "active_fire", "smoke_present",
                     "components", "hazards", "signs_of_life", "adjuster_summary", "recommended_actions", "confidence"],
    },
}

SYSTEM = """You are the vision system on a disaster-response drone surveying homes after a wildfire.
You assist property insurance adjusters (first-pass triage, not a final determination) and flag any sign of
people or animals for rescue teams.

Rules:
- Assess the PRIMARY structure: the building nearest the center of the frame.
- Use CAL FIRE DINS categories: No Damage; Affected (1-9%); Minor (10-25%); Major (26-50%); Destroyed (>50%).
  Use "Unknown" if no building is clearly visible.
- Rate EVERY component you can see, even partly (a photo of a house on a phone or screen counts).
  Use not_visible only when that part is completely out of frame. Burned or charred = severe; collapsed or missing = destroyed.
- Keep every text field short (adjuster_summary under 40 words) so the JSON is complete.
- The feed may be a demo: a camera pointed at a printed photo or a screen. Assess the scene depicted, ignore
  screen bezels, glare, or hands.
- Signs of life matter most: report any person, animal, or movement, even partial or uncertain."""


def _downscale(frame: np.ndarray, max_side=1024) -> np.ndarray:
    h, w = frame.shape[:2]
    s = max_side / max(h, w)
    if s < 1:
        frame = cv2.resize(frame, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    return frame


def _context_text(parcel, context) -> str:
    lines = []
    if parcel:
        lines.append(f"Property on file: {parcel['address']} ({parcel.get('structure_type')}, "
                     f"{parcel.get('stories')} story, {parcel.get('sqft')} sqft, built {parcel.get('year_built')}, "
                     f"roof: {parcel.get('roof_type')}, construction: {parcel.get('construction')}).")
    else:
        lines.append("No parcel on file for this location.")
    if context.get("onboard_detections"):
        lines.append(f"Onboard detector currently sees: {context['onboard_detections']}.")
    if context.get("radar"):
        lines.append(f"Through-wall radar reports: {context['radar']}.")
    lines.append("Record your assessment with the tool.")
    return "\n".join(lines)


def jpeg_b64(frame: np.ndarray, max_side=1024, quality=80) -> str:
    frame = _downscale(frame, max_side)
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return base64.b64encode(buf.tobytes()).decode()


def category_from_pct(pct: float) -> str:
    if pct < 1:
        return "No Damage"
    if pct < 10:
        return "Affected (1-9%)"
    if pct < 26:
        return "Minor (10-25%)"
    if pct <= 50:
        return "Major (26-50%)"
    return "Destroyed (>50%)"


class ClaudeAssessor:
    name = "claude"

    def __init__(self, model: str = DEFAULT_MODEL):
        import anthropic
        self.client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
        self.model = model
        self.name = f"claude:{model}"

    def assess(self, frame, parcel: dict | None, context: dict) -> dict:

        msg = self.client.messages.create(
            model=self.model,
            max_tokens=1200,
            system=SYSTEM,
            tools=[ASSESS_TOOL],
            tool_choice={"type": "tool", "name": ASSESS_TOOL["name"]},
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": jpeg_b64(frame)}},
                {"type": "text", "text": _context_text(parcel, context)},
            ]}],
        )
        for block in msg.content:
            if block.type == "tool_use":
                return dict(block.input)
        raise RuntimeError("model returned no tool_use block")


class GeminiAssessor:
    """Same prompt and schema as Claude, via Google's Gemini API (has a rate-limited free tier)."""

    def __init__(self, model: str):
        from google import genai
        key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        self.client = genai.Client(api_key=key)
        self.model = model
        self.name = f"gemini:{model}"

    def assess(self, frame, parcel, context) -> dict:
        import json
        from google.genai import types
        ok, buf = cv2.imencode(".jpg", _downscale(frame), [cv2.IMWRITE_JPEG_QUALITY, 80])
        resp = self.client.models.generate_content(
            model=self.model,
            contents=[types.Part.from_bytes(data=buf.tobytes(), mime_type="image/jpeg"),
                      _context_text(parcel, context).replace("Record your assessment with the tool.",
                                                              "Return your assessment as JSON.")],
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM,
                response_mime_type="application/json",
                response_json_schema=ASSESS_TOOL["input_schema"],
                temperature=0.2,
            ),
        )
        return json.loads(resp.text)


def _repair_truncated_json(t: str) -> str:
    """Close an object that was cut off mid-stream: drop the dangling partial field, close strings/brackets."""
    stack, in_str, esc, last_safe = [], False, False, 0
    for i, ch in enumerate(t):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            stack.append("}" if ch == "{" else "]")
        elif ch in "}]":
            if stack:
                stack.pop()
            last_safe = i + 1
        elif ch == ",":
            last_safe = i  # everything before this comma is complete
    out = t[:last_safe].rstrip().rstrip(",")
    # recompute what is still open in the kept prefix
    stack, in_str, esc = [], False, False
    for ch in out:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            stack.append("}" if ch == "{" else "]")
        elif ch in "}]" and stack:
            stack.pop()
    return out + "".join(reversed(stack))


def _extract_json(text: str) -> dict:
    import json, re
    text = re.sub(r"<think>.*?(</think>|$)", "", text or "", flags=re.S).strip()
    text = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.M).strip()
    start = text.find("{")
    if start == -1:
        raise ValueError(f"no JSON in model output: {text[:300]!r}")
    body = text[start:]
    try:
        return json.loads(body)
    except Exception:
        pass
    end = body.rfind("}")
    if end != -1:
        try:
            return json.loads(body[:end + 1])
        except Exception:
            pass
    repaired = _repair_truncated_json(body)
    try:
        r = json.loads(repaired)
        r.setdefault("adjuster_summary", "")
        r["_repaired"] = True
        return r
    except Exception:
        raise ValueError(f"unparseable model output ({len(text)} chars): {text[:400]!r}")


_COMP_KEYS = [  # (substring in the model's key, our key)
    ("roof", "roof"), ("wall", "exterior_walls"), ("exterior", "exterior_walls"), ("siding", "exterior_walls"),
    ("window", "windows_doors"), ("door", "windows_doors"), ("glass", "windows_doors"),
    ("frame", "structural_frame"), ("struct", "structural_frame"), ("foundation", "structural_frame"),
    ("garage", "garage_outbuildings"), ("outbuild", "garage_outbuildings"), ("shed", "garage_outbuildings"),
    ("fence", "fences_walls"), ("vehicle", "vehicles"), ("car", "vehicles"), ("truck", "vehicles"),
    ("landscap", "landscaping_vegetation"), ("vegetat", "landscaping_vegetation"), ("tree", "landscaping_vegetation"),
    ("yard", "landscaping_vegetation"), ("garden", "landscaping_vegetation"),
]


def _severity(v) -> str:
    """Map whatever words the model used onto none|minor|moderate|severe|destroyed|not_visible."""
    if isinstance(v, dict):
        v = next((v[k] for k in ("damage", "severity", "level", "status", "condition", "state") if k in v), "")
    t = str(v or "").lower().replace("_", " ").strip()
    if not t or any(w in t for w in ("not visible", "unknown", "n/a", "unclear", "cannot see", "can't see", "obscured", "out of frame")):
        return "not_visible"
    if t in ("none", "no", "ok", "fine", "good") or any(w in t for w in ("no damage", "undamaged", "intact", "no visible damage")):
        return "none"
    if any(w in t for w in ("destroy", "gone", "missing", "total", "complete", "fully collapsed", "burned down", "burnt down")):
        return "destroyed"
    if "collapse" in t and not any(w in t for w in ("partial", "partly", "sag")):
        return "destroyed"
    if any(w in t for w in ("severe", "heavy", "major", "char", "burned", "burnt", "badly", "partial", "partly", "sag", "caved",
                            "broken", "shatter", "blown out", "melted")):
        return "severe"
    if any(w in t for w in ("moderate", "medium", "burn", "damaged")):
        return "moderate"
    if any(w in t for w in ("minor", "light", "slight", "smoke", "soot", "scorch", "affected", "small")):
        return "minor"
    return "not_visible"


def _components(raw) -> dict:
    out = {c: "not_visible" for c in COMPONENTS}
    if isinstance(raw, list):  # [{"name": "roof", "damage": "severe"}, ...]
        raw = {str(i.get("name") or i.get("component") or i.get("part") or ""): i for i in raw if isinstance(i, dict)}
    if not isinstance(raw, dict):
        return out
    for k, v in raw.items():
        kk = str(k).lower()
        ours = kk if kk in out else next((c for sub, c in _COMP_KEYS if sub in kk), None)
        if ours:
            sev = _severity(v)
            # keep the worst rating if two of the model's keys map to the same part (e.g. windows + doors)
            rank = ["not_visible", "none", "minor", "moderate", "severe", "destroyed"]
            if rank.index(sev) > rank.index(out[ours]):
                out[ours] = sev
    return out


def normalize(r: dict) -> dict:
    """Smaller models drift from the schema; coerce everything into the shape the app expects."""
    cat = str(r.get("damage_category", "Unknown"))
    if cat not in DAMAGE_CATS:
        low = cat.lower()
        keys = [("destroy", "Destroyed (>50%)"), ("major", "Major (26-50%)"), ("minor", "Minor (10-25%)"),
                ("affect", "Affected (1-9%)"), ("no damage", "No Damage"), ("undamaged", "No Damage"), ("none", "No Damage")]
        cat = next((c for k, c in keys if k in low), "Unknown")
    try:
        pct = float(r.get("damage_percent", 0) or 0)
    except (TypeError, ValueError):
        pct = 0.0
    comps = _components(r.get("components") or r.get("parts") or r.get("component_damage"))
    # Some models put part ratings at the top level instead of inside "components"
    for k, v in r.items():
        if k not in ("components", "damage_category", "damage_percent", "hazards", "signs_of_life", "confidence") and isinstance(v, (str, dict)):
            for sub, c in _COMP_KEYS:
                if sub in k.lower() and comps[c] == "not_visible":
                    comps[c] = _severity(v)
                    break
    as_list = lambda v: [str(x) for x in v] if isinstance(v, list) else ([str(v)] if v else [])
    try:
        conf = float(r.get("confidence", 0.5))
    except (TypeError, ValueError):
        conf = 0.5
    if cat == "Unknown":   # model rated the parts but skipped the overall call: derive it from the worst part
        worst = max((["none", "minor", "moderate", "severe", "destroyed"].index(v) for v in comps.values() if v != "not_visible"), default=None)
        if worst is not None:
            cat = ["No Damage", "Affected (1-9%)", "Minor (10-25%)", "Major (26-50%)", "Destroyed (>50%)"][worst]
    if pct <= 0 and cat not in ("No Damage", "Unknown"):   # category given without a number: use its midpoint
        pct = {"Affected (1-9%)": 5, "Minor (10-25%)": 18, "Major (26-50%)": 38, "Destroyed (>50%)": 80}[cat]
    return {
        "structure_visible": bool(r.get("structure_visible", cat != "Unknown")),
        "damage_category": cat,
        "damage_percent": max(0.0, min(100.0, pct)),
        "active_fire": bool(r.get("active_fire", False)),
        "smoke_present": bool(r.get("smoke_present", False)),
        "components": comps,
        "hazards": as_list(r.get("hazards")),
        "signs_of_life": as_list(r.get("signs_of_life")),
        "other_structures_in_frame": as_list(r.get("other_structures_in_frame")),
        "adjuster_summary": str(r.get("adjuster_summary", "")),
        "recommended_actions": as_list(r.get("recommended_actions")),
        "confidence": max(0.0, min(1.0, conf if conf <= 1 else conf / 100)),
    }


class NemotronAssessor:
    """NVIDIA Nemotron Nano VL through NVIDIA's hosted API (build.nvidia.com, OpenAI-compatible).
    Point NVIDIA_BASE_URL at a local NIM container instead to run it on your own GPU."""

    def __init__(self, model: str):
        import json
        self.key = os.environ.get("NVIDIA_API_KEY")
        if not self.key:
            raise RuntimeError("NVIDIA_API_KEY not set")
        self.url = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1").rstrip("/") + "/chat/completions"
        self.model = model
        self.name = f"nemotron:{model.split('/')[-1]}"
        self.schema_txt = json.dumps(ASSESS_TOOL["input_schema"])
        self.guided = True       # NIM structured output; switched off automatically if the endpoint rejects it
        self.thinking_kw = True  # chat_template_kwargs.enable_thinking=False; same auto-fallback

    def assess(self, frame, parcel, context) -> dict:
        import httpx
        prompt = _context_text(parcel, context).replace(
            "Record your assessment with the tool.",
            "Respond with ONLY a compact JSON object (no prose, no code fences, keep every string short) "
            "that matches this JSON schema:\n" + self.schema_txt)
        body = {
            "model": self.model,
            "messages": [
                # '/no_think' turns off Nemotron's reasoning trace so the token budget goes to the answer
                {"role": "system", "content": "/no_think\n" + SYSTEM},
                {"role": "user", "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{jpeg_b64(frame)}"}},
                ]},
            ],
            "max_tokens": 4096,
            "temperature": 0.2,
        }
        optional = []
        if self.guided:
            optional.append(("nvext", {"guided_json": ASSESS_TOOL["input_schema"]}))
        if self.thinking_kw:
            optional.append(("chat_template_kwargs", {"enable_thinking": False}))
        for k, v in optional:
            body[k] = v
        headers = {"Authorization": f"Bearer {self.key}", "Accept": "application/json"}
        r = httpx.post(self.url, headers=headers, json=body, timeout=120)
        # if the endpoint rejects an optional parameter, drop them one at a time and retry
        while r.status_code in (400, 422) and optional:
            k, _ = optional.pop()
            body.pop(k, None)
            if k == "nvext":
                self.guided = False
            else:
                self.thinking_kw = False
            r = httpx.post(self.url, headers=headers, json=body, timeout=120)
        if r.status_code >= 400:
            raise RuntimeError(f"NVIDIA API {r.status_code}: {r.text[:300]}")
        choice = r.json()["choices"][0]
        content = choice["message"].get("content") or ""
        self.last_raw = content
        if choice.get("finish_reason") == "length":
            print(f"[nemotron] response hit max_tokens ({len(content)} chars); repairing partial JSON")
        return _extract_json(content)


class HeuristicAssessor:
    """Offline fallback: charred (very dark) + ash (grey, desaturated) + flame pixel ratios."""
    name = "offline-heuristic"

    def assess(self, frame, parcel, context) -> dict:
        hsv = cv2.cvtColor(cv2.resize(frame, (320, 240)), cv2.COLOR_BGR2HSV)
        s, v = hsv[..., 1], hsv[..., 2]
        charred = float(np.mean((v < 45) & (s < 70)))
        ash = float(np.mean((s < 35) & (v > 70) & (v < 180)))
        fire, _ = detect_fire(frame)
        pct = float(np.clip((charred * 1.3 + ash * 0.5 + fire * 4) * 100, 0, 100))
        cat = category_from_pct(pct)
        sev = "destroyed" if pct > 50 else "severe" if pct > 25 else "moderate" if pct > 10 else "minor" if pct > 1 else "none"
        return {
            "structure_visible": True,
            "damage_category": cat,
            "damage_percent": round(pct, 1),
            "active_fire": fire > 0.01,
            "smoke_present": ash > 0.25,
            "components": {c: ("not_visible" if c in ("vehicles", "structural_frame") else sev) for c in COMPONENTS},
            "hazards": ["Active flame visible"] if fire > 0.01 else [],
            "signs_of_life": [f"Onboard detector: {context['onboard_life']}"] if context.get("onboard_life") else [],
            "other_structures_in_frame": [],
            "adjuster_summary": (f"Offline colour heuristic: {charred:.0%} charred, {ash:.0%} ash-grey, "
                                 f"{fire:.1%} flame pixels. Low-confidence placeholder until AI assessment is available."),
            "recommended_actions": ["Re-run with AI assessment enabled", "Field verification required"],
            "confidence": 0.3,
        }


class AssessmentWorker:
    """Single background worker. Only the newest request is kept, so a slow API never queues up stale frames."""

    def __init__(self, primary, fallback, on_result: Callable[[str | None, dict, np.ndarray], None]):
        self.primary = primary
        self.fallback = fallback
        self.on_result = on_result
        self._pending = None
        self._cv = threading.Condition()
        self.busy = False
        self.last_error: str | None = None
        self.calls = 0
        self.last_raw = None
        self.last_result = None
        threading.Thread(target=self._loop, daemon=True).start()

    def submit(self, frame, parcel, context):
        with self._cv:
            self._pending = (frame, parcel, context, time.time())
            self._cv.notify()

    def _loop(self):
        while True:
            with self._cv:
                while self._pending is None:
                    self._cv.wait()
                frame, parcel, context, t0 = self._pending
                self._pending = None
                self.busy = True
            engine = self.primary or self.fallback
            try:
                result = normalize(engine.assess(frame, parcel, context))
                self.last_error = None
            except Exception as e:
                traceback.print_exc()
                self.last_error = f"{type(e).__name__}: {e}"
                engine = self.fallback
                result = self.fallback.assess(frame, parcel, context)
            self.calls += 1
            result["_engine"] = engine.name
            result["_latency_s"] = round(time.time() - t0, 2)
            result["_timestamp"] = time.time()
            self.last_raw = getattr(engine, "last_raw", None)
            self.last_result = result
            c = result.get("components", {})
            seen = ", ".join(f"{k.split('_')[0]}={v}" for k, v in c.items() if v != "not_visible") or "no parts rated"
            where = parcel["address"].split(",")[0] if parcel else "no parcel"
            print(f"[ai] {where}: {result.get('damage_category')} {result.get('damage_percent', 0):.0f}% | {seen} "
                  f"| fire={result.get('active_fire')} | {engine.name.split(':')[0]} {result['_latency_s']}s")
            self.busy = False
            try:
                self.on_result(parcel["parcel_id"] if parcel else None, result, frame)
            except Exception:
                traceback.print_exc()


def pick_provider(requested: str) -> str:
    """auto: whichever key is set (NVIDIA, then Claude, then Gemini), else offline."""
    if requested != "auto":
        return requested
    if os.environ.get("NVIDIA_API_KEY"):
        return "nemotron"
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "claude"
    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return "gemini"
    return "none"


def make_assessor(provider: str, model: str | None):
    fallback = HeuristicAssessor()
    if provider == "none":
        print("[assess] No AI provider (set NVIDIA_API_KEY, ANTHROPIC_API_KEY or GEMINI_API_KEY) -> offline heuristic only.")
        return None, fallback
    model = model or DEFAULT_MODELS[provider]
    try:
        cls = {"claude": ClaudeAssessor, "gemini": GeminiAssessor, "nemotron": NemotronAssessor}[provider]
        return cls(model), fallback
    except Exception as e:
        print(f"[assess] could not init {provider} client ({e}); using offline heuristic")
        return None, fallback
