"""Survey agent: Nemotron plans the survey and drives Drone-Eye through tools.

For each home it decides what to do next: look at the home (Nemotron vision), pull the policy, check for
people, ask for a better camera angle when unsure, price the claim, raise alerts, file the claim PDF, then
choose where the drone goes next from the priority list. Every thought, tool call and result is written to
the agent log that the dashboard shows live.

Planner = NemotronPlanner (OpenAI-style tool calling on build.nvidia.com; falls back to JSON actions if the
endpoint refuses tools) or RulePlanner (same tools, fixed rules) when no NVIDIA key is set.
"""
from __future__ import annotations

import collections
import json
import os
import re
import threading
import time
import traceback

from . import pricing, triage

MAX_STEPS_PER_HOME = 9
LOOK_TIMEOUT_S = 150

SYSTEM = """You are Drone-Eye's survey agent after a {hazard} disaster. You control a camera drone flying over a
street of insured homes. Your goals, in order:
1. Find people who may need help and make sure responders know (nobody gets overlooked).
2. Rate every home's damage accurately from the camera, getting a better view when unsure.
3. Prepare the insurance claim for damaged homes so adjusters can act fast.

Work one home at a time using the tools. A good routine for each home:
- look_at_home to have the vision model rate the current camera frame.
- If it says Unknown or confidence is below 0.55, request_new_angle once, then look_at_home again.
- lookup_property for occupants and coverage, and check_for_people.
- If people were seen, or people live there and the home is Major/Destroyed with nobody confirmed safe,
  raise_alert (urgency "people"). Raise "hazard" alerts for active fire, collapse, power lines or deep water.
- estimate_payout, then file_claim_report for any damaged home.
- Finally call next_home. Use survey_status to see the priority list when choosing where to go.
Call exactly one tool per turn. Keep any text you write to one short sentence. Never invent results:
only the tools tell you what is true."""


def _tools():
    def t(name, desc, props, req=None):
        return {"type": "function", "function": {"name": name, "description": desc, "parameters": {
            "type": "object", "properties": props, "required": req if req is not None else list(props)}}}
    pid = {"type": "string", "description": "parcel id, e.g. DEMO-0001"}
    return [
        t("survey_status", "Priority list of homes (who needs help first), homes not checked yet, and the home in view.",
          {"focus": {"type": "string", "enum": ["priorities", "unchecked", "all"]}}),
        t("look_at_home", "Capture the current drone camera frame and have the Nemotron vision model rate the damage. "
          "Takes 10-40 s. Returns rating, confidence, damaged parts, hazards and signs of life.",
          {"reason": {"type": "string", "description": "why you are looking (shown to the operator)"}}),
        t("request_new_angle", "Ask the pilot for a better view (closer, lower, other side, tilt camera down), "
          "then wait a few seconds. Use when the rating is Unknown or low confidence.",
          {"instruction": {"type": "string", "description": "short instruction for the pilot"}}),
        t("lookup_property", "Policy and property record: occupants and pets on file, coverages, flood policy.", {"parcel_id": pid}),
        t("check_for_people", "Signs of life for a home from the vision model, onboard detector and radar.", {"parcel_id": pid}),
        t("estimate_payout", "Insurance payout estimate for the home from its latest rating and policy.", {"parcel_id": pid}),
        t("raise_alert", "Send an alert to responders and the adjuster team.",
          {"parcel_id": pid, "urgency": {"type": "string", "enum": ["people", "hazard", "info"]},
           "message": {"type": "string", "description": "one sentence"}}),
        t("file_claim_report", "Generate the claim PDF (photos, damage, payout, next steps) for a home.", {"parcel_id": pid}),
        t("next_home", "Move the drone to another home. Use 'auto' for the most urgent home not yet surveyed.",
          {"parcel_id": {"type": "string", "description": "parcel id or 'auto'"}}),
        t("finish_survey", "Stop when every home has been checked.", {"summary": {"type": "string"}}),
    ]


TOOLS = _tools()
TOOL_NAMES = {t["function"]["name"] for t in TOOLS}


# =====================================================================================================
class NemotronPlanner:
    def __init__(self, model):
        self.key = os.environ.get("NVIDIA_API_KEY")
        if not self.key:
            raise RuntimeError("NVIDIA_API_KEY not set")
        self.url = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1").rstrip("/") + "/chat/completions"
        self.model = model
        short = model.split("/")[-1]
        self.name = "Nemotron 3.5 Super VL" if "nemotron-3.5-super-vl" in short else f"Nemotron ({short})"
        self.native_tools = True      # OpenAI tool calling; off if the endpoint refuses it
        self.effort = True            # reasoning_effort "low": short visible reasoning, fast enough for a live demo

    def _post(self, body):
        import httpx
        r = httpx.post(self.url, json=body, timeout=120,
                       headers={"Authorization": f"Bearer {self.key}", "Accept": "application/json"})
        return r

    def next(self, messages):
        body = {"model": self.model, "messages": messages, "max_tokens": 3000, "temperature": 0.6, "top_p": 0.95}
        if self.native_tools:
            body["tools"] = TOOLS
            body["tool_choice"] = "auto"
        if self.effort:
            body["reasoning_effort"] = "low"
        else:
            body["chat_template_kwargs"] = {"enable_thinking": False}
        r = self._post(body)
        if r.status_code in (400, 422) and self.native_tools and "tool" in r.text.lower():
            self.native_tools = False
            return self.next(messages)
        if r.status_code in (400, 422) and self.effort:
            self.effort = False
            body.pop("reasoning_effort", None)
            body["chat_template_kwargs"] = {"enable_thinking": False}
            r = self._post(body)
        if r.status_code in (400, 422) and self.native_tools:
            self.native_tools = False
            return self.next(messages)
        if r.status_code >= 400:
            raise RuntimeError(f"NVIDIA API {r.status_code}: {r.text[:200]}")
        msg = r.json()["choices"][0]["message"]
        thought = (msg.get("reasoning") or msg.get("reasoning_content") or "").strip()
        text = (msg.get("content") or "").strip()
        calls = msg.get("tool_calls") or []
        if calls:
            c = calls[0]
            fn = c.get("function") or {}
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            assistant = {"role": "assistant", "content": text or None,
                         "tool_calls": [{"id": c.get("id") or "call_0", "type": "function",
                                         "function": {"name": fn.get("name"), "arguments": json.dumps(args)}}]}
            return {"thought": thought, "say": text, "tool": fn.get("name"), "args": args,
                    "assistant": assistant, "call_id": c.get("id") or "call_0"}
        # JSON-action fallback: {"say": "...", "tool": "...", "args": {...}}
        from .assess import _extract_json
        try:
            j = _extract_json(text)
        except Exception:
            j = {}
        tool = j.get("tool") if isinstance(j, dict) else None
        return {"thought": thought, "say": (j.get("say") if isinstance(j, dict) else "") or ("" if tool else text[:200]),
                "tool": tool, "args": (j.get("args") or {}) if isinstance(j, dict) else {},
                "assistant": {"role": "assistant", "content": text}, "call_id": None}

    def json_instructions(self):
        lines = [f"- {t['function']['name']}({', '.join(t['function']['parameters']['properties'])}): "
                 f"{t['function']['description']}" for t in TOOLS]
        return ("\nTools:\n" + "\n".join(lines) + '\nReply with ONLY JSON: {"say": "one short sentence", '
                '"tool": "<tool name>", "args": {...}}')


class RulePlanner:
    """Same tools, fixed rules. Used without an NVIDIA key so the demo still runs (and for tests)."""
    name = "offline rules"
    native_tools = True

    def __init__(self):
        self.ep = {}

    def reset(self, pid):
        self.ep = {"pid": pid, "done": []}

    def next(self, messages):
        ep, pid = self.ep, self.ep.get("pid")
        done = ep["done"]
        last = ep.get("last") or {}

        def go(tool, args, say):
            done.append(tool)
            return {"thought": "", "say": say, "tool": tool, "args": args, "assistant": None, "call_id": None}
        if "look_at_home" not in done:
            return go("look_at_home", {"reason": "first look at this home"}, "Taking a first look at this home.")
        look = ep.get("look") or {}
        unsure = look.get("damage_category", "Unknown").startswith("Unknown") or (look.get("confidence") or 0) < 0.55
        if unsure and "request_new_angle" not in done:
            return go("request_new_angle", {"instruction": "Move closer and tilt the camera down onto the roof"},
                      "The view is not clear enough, asking the pilot for a better angle.")
        if unsure and done.count("look_at_home") < 2:
            return go("look_at_home", {"reason": "second look from the new angle"}, "Looking again from the new angle.")
        for tool, say in (("lookup_property", "Checking who lives here and the policy."),
                          ("check_for_people", "Checking for any signs of people.")):
            if tool not in done:
                return go(tool, {"parcel_id": pid}, say)
        heavy = str(look.get("damage_category", "")).startswith(("Major", "Destroyed"))
        people = ep.get("people") or {}
        occ = (ep.get("property") or {}).get("occupants_on_file") or 0
        if "raise_alert" not in done and (people.get("seen") or (heavy and occ)):
            msg = ("Possible people at this home: " + "; ".join(people.get("seen")[:2])) if people.get("seen") else \
                f"{occ} people live here and the home is {look.get('damage_category')}; nobody confirmed safe."
            return go("raise_alert", {"parcel_id": pid, "urgency": "people", "message": msg}, "Alerting responders.")
        damaged = heavy or str(look.get("damage_category", "")).startswith(("Minor", "Affected"))
        if damaged and "estimate_payout" not in done:
            return go("estimate_payout", {"parcel_id": pid}, "Pricing the claim.")
        if damaged and "file_claim_report" not in done:
            return go("file_claim_report", {"parcel_id": pid}, "Filing the claim report.")
        return go("next_home", {"parcel_id": "auto"}, "Moving to the most urgent home not yet checked.")

    def observe(self, tool, result):
        if tool == "look_at_home":
            self.ep["look"] = result
        elif tool == "lookup_property":
            self.ep["property"] = result
        elif tool == "check_for_people":
            self.ep["people"] = result


# =====================================================================================================
class SurveyAgent:
    def __init__(self, pipe, planner, report_dir):
        self.pipe, self.state, self.tel = pipe, pipe.state, pipe.tel
        self.planner = planner
        self.report_dir = report_dir
        os.makedirs(report_dir, exist_ok=True)
        self.running = False
        self.visited: set[str] = set()
        self.log = collections.deque(maxlen=300)
        self.current = None
        self.goal = ""
        self.operator = None          # {"text", "t"} request shown to the pilot
        self.steps = 0
        self._seq = 0
        self._thread = None
        self._survey = None

    # ---------- public ----------
    def start(self):
        if self.running:
            return
        if self._survey != self.state.survey_id:
            self.visited.clear()
            self._survey = self.state.survey_id
        self.running = True
        self.pipe.auto_paused = True            # the agent decides when to look
        self._log("info", f"Agent started. Planner: {self.planner.name}.")
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self, why="Stopped by the operator."):
        if self.running:
            self.running = False
            self._log("info", why)
        self.pipe.auto_paused = False
        self.operator = None
        self.goal = ""

    def view(self, n=60):
        return {"running": self.running, "planner": self.planner.name, "steps": self.steps,
                "current": self.current, "goal": self.goal, "operator": self.operator,
                "visited": sorted(self.visited),
                "native_tools": getattr(self.planner, "native_tools", True),
                "log": list(self.log)[-n:]}

    # ---------- internals ----------
    def _log(self, kind, text, **kw):
        self._seq += 1
        e = {"id": self._seq, "t": time.time(), "kind": kind, "text": str(text)[:600], "home": self.current, **kw}
        self.log.append(e)
        print(f"[agent] {kind:7s} {e['text'][:160]}")
        return e

    def _home_in_view(self):
        return self.state.live.get("target_parcel_id")

    def _run(self):
        try:
            while self.running:
                pid = self._home_in_view()
                if not pid:
                    time.sleep(1)
                    continue
                self._episode(pid)
        except Exception as e:
            traceback.print_exc()
            self._log("error", f"Agent stopped: {type(e).__name__}: {e}")
            self.running = False
            self.pipe.auto_paused = False

    def _brief(self, pid):
        p = self.state.parcels.get(pid)
        r = triage.rank(self.state)
        top = [f"{h['parcel_id']} {h['address']}: {h['tier_label']} ({'; '.join(h['reasons'][:2])})" for h in r["homes"][:4]]
        return (f"The drone is now looking at {pid}, {p['address']}. Homes checked {r['checked']}/{r['total']}. "
                f"Already surveyed this flight: {', '.join(sorted(self.visited)) or 'none'}.\n"
                f"Current priorities: " + (" | ".join(top) or "none yet") + "\nStart with this home.")

    def _episode(self, pid):
        self.current = pid
        self.goal = f"Survey {self.state.parcels.get(pid)['address'].split(',')[0]}"
        hz = self.state.hazard
        system = SYSTEM.format(hazard={"wildfire": "wildfire", "hurricane": "hurricane / wind storm", "flood": "flood"}.get(hz, hz))
        if not getattr(self.planner, "native_tools", True) and hasattr(self.planner, "json_instructions"):
            system += self.planner.json_instructions()
        messages = [{"role": "system", "content": system}, {"role": "user", "content": self._brief(pid)}]
        if isinstance(self.planner, RulePlanner):
            self.planner.reset(pid)
        self._log("goal", self.goal)
        moved = False
        for _ in range(MAX_STEPS_PER_HOME):
            if not self.running:
                return
            was_native = getattr(self.planner, "native_tools", True)
            act = self.planner.next(messages)
            if was_native and not getattr(self.planner, "native_tools", True):
                self._log("info", "This endpoint refused native tool calls; switching to JSON actions.")
                messages[0]["content"] = system + self.planner.json_instructions()
            if act.get("thought"):
                self._log("think", _short(act["thought"], 280))
            if act.get("say"):
                self._log("say", act["say"])
            tool, args = act.get("tool"), act.get("args") or {}
            if tool not in TOOL_NAMES:
                self._log("info", "No tool chosen; moving on.")
                break
            self.steps += 1
            self._log("tool", f"{tool}({_fmt_args(args)})", tool=tool, args=args)
            try:
                result = self._exec(tool, args, pid)
            except Exception as e:
                result = {"error": f"{type(e).__name__}: {e}"}
            self._log("result", _summary(tool, result), tool=tool, data=_trim(result))
            if isinstance(self.planner, RulePlanner):
                self.planner.observe(tool, result)
            # conversation memory for Nemotron
            if act.get("assistant") is not None:
                messages.append(act["assistant"])
                payload = json.dumps(_trim(result))[:2500]
                if act.get("call_id"):
                    messages.append({"role": "tool", "tool_call_id": act["call_id"], "content": payload})
                else:
                    messages.append({"role": "user", "content": f"Result of {tool}: {payload}\nNext action?"})
            if tool == "finish_survey":
                self.stop("Survey finished.")
                return
            if tool == "next_home":
                moved = True
                break
        self.visited.add(pid)
        if not moved and self.running:
            self._exec("next_home", {"parcel_id": "auto"}, pid)

    # ---------- tools ----------
    def _exec(self, tool, a, pid):
        st = self.state
        target = a.get("parcel_id") or pid
        if target not in st.parcels.parcels and tool not in ("next_home",):
            target = pid
        if tool == "survey_status":
            r = triage.rank(st)
            return {"home_in_view": self._home_in_view(), "checked": r["checked"], "total": r["total"],
                    "priorities": [{k: h[k] for k in ("parcel_id", "address", "tier_label", "reasons")} for h in r["homes"][:6]],
                    "not_checked": [u["parcel_id"] for u in r["unchecked"]][:12],
                    "already_surveyed": sorted(self.visited)}
        if tool == "look_at_home":
            return self._look(pid, a.get("reason") or "")
        if tool == "request_new_angle":
            self.operator = {"text": a.get("instruction") or "Get a closer view of the home", "t": time.time(), "home": pid}
            self._log("operator", f"Asked the pilot: {self.operator['text']}")
            time.sleep(6)
            return {"ok": True, "note": "Pilot asked; look again now."}
        if tool == "lookup_property":
            p = st.parcels.get(target)
            pol, fp = p.get("policy") or {}, p.get("flood_policy") or {}
            return {"parcel_id": target, "address": p["address"], "occupants_on_file": p.get("occupants_on_file"),
                    "pets_on_file": p.get("pets_on_file"), "structure": f"{p.get('structure_type')}, {p.get('stories')} story, {p.get('sqft')} sq ft",
                    "year_built": p.get("year_built"), "policy_number": pol.get("policy_number"),
                    "dwelling_coverage": pol.get("coverage_a_dwelling"), "deductible": pol.get("deductible"),
                    "flood_policy": bool(fp)}
        if tool == "check_for_people":
            a_ = st.best(target) or {}
            alerts = [x for x in st.alerts if x.get("parcel_id") == target and x.get("kind") == "life"]
            seen = [s for s in (a_.get("signs_of_life") or []) if s and not re.match(r"^(none|no )", s, re.I)]
            seen += [f"{x['label']} ({x['source']}, {x['confidence']:.0%})" for x in alerts if not x.get("acknowledged")]
            return {"parcel_id": target, "seen": seen, "confirmed_safe": any(x.get("acknowledged") for x in alerts),
                    "occupants_on_file": st.parcels.get(target).get("occupants_on_file")}
        if tool == "estimate_payout":
            a_ = st.best(target)
            if not a_:
                return {"error": "No rating yet. Call look_at_home first."}
            e = pricing.estimate(st.parcels.get(target), a_, st.hazard) or {}
            return {k: e.get(k) for k in ("status", "covered", "paid_by", "net_estimate", "range_low", "range_high",
                                           "deductible", "uninsured_loss", "total_loss")}
        if tool == "raise_alert":
            urg = a.get("urgency") or "info"
            msg = a.get("message") or "Agent alert"
            st.raise_alert(target, "agent", msg, 0.9, kind="agent",
                           key=f"agent:{urg}", extra={"urgency": urg, "by": "agent"})
            self._log("alert", f"{st.parcels.get(target)['address'].split(',')[0]}: {msg}", urgency=urg)
            return {"ok": True, "sent_to": "responders and adjuster team", "urgency": urg}
        if tool == "file_claim_report":
            if not st.best(target):
                return {"error": "No rating yet."}
            from .claim_pdf import build_claim_pdf
            data = build_claim_pdf(st, [target], prepared_for=getattr(st, "report_to", "Claims adjuster"),
                                   photo_limit=getattr(st, "report_photos", 6))
            slug = re.sub(r"[^A-Za-z0-9]+", "_", st.parcels.get(target)["address"].split(",")[0]).strip("_")
            name = f"claim_{slug}_{time.strftime('%Y%m%d-%H%M%S')}.pdf"
            with open(os.path.join(self.report_dir, name), "wb") as f:
                f.write(data)
            return {"ok": True, "file": f"/reports/{name}", "pages": data.count(b"/Type /Page") - data.count(b"/Type /Pages")}
        if tool == "next_home":
            return self._move(a.get("parcel_id") or "auto", pid)
        if tool == "finish_survey":
            return {"ok": True}
        return {"error": f"unknown tool {tool}"}

    def _look(self, pid, reason):
        st = self.state
        t0 = time.time()
        self.goal = f"Looking at {st.parcels.get(pid)['address'].split(',')[0]}" + (f": {reason}" if reason else "")
        self.pipe.force_assess(manual=True, by="agent")
        while time.time() - t0 < LOOK_TIMEOUT_S and self.running:
            for r in reversed(st.assessments.get(pid) or []):
                if r.get("_timestamp", 0) > t0:
                    self.operator = None
                    return {k: r.get(k) for k in ("damage_category", "damage_percent", "confidence", "active_fire",
                                                  "components", "hazards", "signs_of_life", "water_depth_ft",
                                                  "tree_on_structure", "adjuster_summary")} | \
                        {"marked_areas": len(r.get("damage_regions") or []), "seconds": round(time.time() - t0, 1)}
            time.sleep(0.5)
        return {"error": "No answer from the vision model in time.", "damage_category": "Unknown", "confidence": 0}

    def _move(self, want, pid):
        st = self.state
        self.visited.add(pid)
        r = triage.rank(st)
        if want == "auto" or want not in st.parcels.parcels or want in self.visited:
            order = [u["parcel_id"] for u in r["unchecked"]] + [h["parcel_id"] for h in r["homes"]]
            nxt = next((x for x in order if x not in self.visited), None)
            # unchecked homes nearest along the street first
            if nxt is None:
                self.stop("Every home on this survey has been checked.")
                return {"ok": True, "done": True}
            want = nxt
        addr = st.parcels.get(want)["address"].split(",")[0]
        pose_live = self.tel.as_dict().get("live")
        if pose_live:
            self.operator = {"text": f"Fly to {addr}", "t": time.time(), "home": want}
            self._log("operator", f"Asked the pilot: fly to {addr}")
            t0 = time.time()
            while time.time() - t0 < 90 and self.running and self._home_in_view() != want:
                time.sleep(1)
            self.operator = None
        else:
            self.tel.sim_goto(want)
            t0 = time.time()
            while time.time() - t0 < 10 and self._home_in_view() != want:
                time.sleep(0.3)
            time.sleep(1.2)   # let the frame settle
        return {"ok": True, "now_at": self._home_in_view(), "address": addr}


# ------------------------------------------------------------------ helpers
def _short(s, n):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _fmt_args(a):
    return ", ".join(f"{k}={_short(v, 60)!r}" if isinstance(v, str) else f"{k}={v}" for k, v in a.items())


def _trim(r):
    if not isinstance(r, dict):
        return r
    out = {}
    for k, v in r.items():
        if k == "components" and isinstance(v, dict):
            v = {kk: vv for kk, vv in v.items() if vv not in ("not_visible", "none")}
        if isinstance(v, str):
            v = _short(v, 300)
        out[k] = v
    return out


def _money(v):
    try:
        return f"${float(v):,.0f}"
    except (TypeError, ValueError):
        return "-"


def _summary(tool, r):
    if not isinstance(r, dict):
        return str(r)
    if r.get("error"):
        return "Problem: " + r["error"]
    if tool == "look_at_home":
        parts = [k.split("_")[0] for k, v in (r.get("components") or {}).items() if v in ("severe", "destroyed")]
        s = f"{r.get('damage_category')} · {float(r.get('damage_percent') or 0):.0f}% · confidence {float(r.get('confidence') or 0):.0%}"
        if parts:
            s += " · worst: " + ", ".join(parts[:3])
        if r.get("signs_of_life"):
            s += " · signs of life: " + "; ".join(r["signs_of_life"][:2])
        return s + f" ({r.get('seconds')} s)"
    if tool == "lookup_property":
        return (f"{r.get('occupants_on_file')} occupants, {r.get('pets_on_file') or 0} pets on file · policy {r.get('policy_number') or 'none'}"
                f"{' · flood policy' if r.get('flood_policy') else ' · no flood policy'}")
    if tool == "check_for_people":
        return ("People: " + "; ".join(r["seen"][:3])) if r.get("seen") else \
            ("Confirmed safe" if r.get("confirmed_safe") else f"No one seen ({r.get('occupants_on_file')} on file, not confirmed)")
    if tool == "estimate_payout":
        if r.get("status") != "ok":
            return "Not enough of the home visible to price"
        if not r.get("covered", True):
            return f"Not covered · {_money(r.get('uninsured_loss'))} uninsured"
        return f"{_money(r.get('net_estimate'))} ({_money(r.get('range_low'))}–{_money(r.get('range_high'))}) · {r.get('paid_by')}"
    if tool == "file_claim_report":
        return f"Claim PDF ready: {r.get('file')}"
    if tool == "next_home":
        return "Survey complete" if r.get("done") else f"Now at {r.get('address')}"
    if tool == "survey_status":
        return f"{r.get('checked')}/{r.get('total')} checked · top: " + \
            ", ".join(f"{h['address']} ({h['tier_label']})" for h in r.get("priorities", [])[:3])
    if tool == "raise_alert":
        return f"Alert sent ({r.get('urgency')})"
    if tool == "request_new_angle":
        return "Pilot asked"
    return _short(json.dumps(r), 200)
