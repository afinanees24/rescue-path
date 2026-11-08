"""Who needs help first. Ranks every home on the survey so no one is overlooked.

Tiers (lower = more urgent):
  1  People seen          signs of life from the AI, the onboard detector, or radar, at a damaged home
  2  Occupants unconfirmed people live there (on file) and the home is badly damaged, nobody confirmed safe
  3  Unsafe site          active fire, collapse, power lines, deep water
  4  Uninsured loss       heavy damage the policy won't pay (e.g. flood with no flood policy)
  5  Damaged              covered damage, needs a claim
  6  No damage
  -  Not checked yet      no AI look so far
"""
from __future__ import annotations

import re
import time

from . import pricing

TIERS = {1: "People seen", 2: "Occupants not confirmed", 3: "Unsafe site", 4: "Uninsured loss",
         5: "Damaged", 6: "No damage", 9: "Not checked yet"}
HEAVY = ("Major", "Destroyed")


def safety_level(a: dict, hazard: str) -> int:
    """0 safe, 1 caution, 2 danger, 3 keep out (same rules as the dashboard)."""
    hz = a.get("hazards") or []
    ft = a.get("water_depth_ft") or 0
    cat = str(a.get("damage_category", ""))
    if (a.get("active_fire") and hazard == "wildfire") or (hazard == "flood" and ft >= 3):
        return 3
    if len(hz) >= 3 or (cat.startswith("Destroyed") and any(re.search(r"collap|fall|unstable", h, re.I) for h in hz)) \
            or any(re.search(r"power line|gas leak|electr", h, re.I) for h in hz) or (hazard == "flood" and ft >= 1):
        return 2
    if hz or (hazard == "flood" and ft > 0.2) or a.get("tree_on_structure"):
        return 1
    return 0


def _life(state, pid, a):
    alerts = [x for x in state.alerts if x.get("parcel_id") == pid and x.get("kind") == "life"]
    open_ = [x for x in alerts if not x.get("acknowledged")]
    seen = [s for s in (a.get("signs_of_life") or []) if s and not re.match(r"^(none|no )", s, re.I)]
    return seen, open_, alerts


def rank(state, now: float | None = None) -> dict:
    now = now or time.time()
    hazard = state.hazard
    homes, unchecked = [], []
    for pid, p in state.parcels.parcels.items():
        a = state.best(pid)
        if not a:
            unchecked.append({"parcel_id": pid, "address": p["address"].split(",")[0], "tier": 9,
                              "tier_label": TIERS[9], "reasons": ["No AI look yet"],
                              "occupants_on_file": p.get("occupants_on_file")})
            continue
        cat = str(a.get("damage_category", "Unknown"))
        heavy = cat.startswith(HEAVY)
        damaged = heavy or cat.startswith(("Minor", "Affected"))
        est = pricing.estimate(p, a, hazard) or {}
        seen, open_alerts, all_alerts = _life(state, pid, a)
        occ = p.get("occupants_on_file") or 0
        safe = safety_level(a, hazard)
        confirmed_safe = any(x.get("acknowledged") for x in state.alerts if x.get("parcel_id") == pid
                             and (x.get("kind") == "life" or x.get("urgency") == "people")) or bool(a.get("_occupants_confirmed"))
        reasons = []
        if seen or open_alerts:
            tier = 1
            reasons += [f"Seen: {s}" for s in seen[:2]] + [f"{x['label']} ({x['source']})" for x in open_alerts[:2]]
        elif heavy and occ and not confirmed_safe:
            tier = 2
            reasons.append(f"{occ} people live here, none confirmed safe")
        elif safe >= 2:
            tier = 3
        elif est.get("status") == "ok" and (not est.get("covered", True) or est.get("uninsured_loss", 0) > 25000) and damaged:
            tier = 4
        elif damaged:
            tier = 5
        else:
            tier = 6
        if safe >= 2:
            reasons.append(["", "", "Dangerous site", "Keep out"][safe] + (": " + "; ".join((a.get("hazards") or [])[:2]) if a.get("hazards") else ""))
        if est.get("status") == "ok" and not est.get("covered", True):
            reasons.append(f"No coverage: {pricing_money(est.get('uninsured_loss'))} uninsured")
        elif est.get("uninsured_loss"):
            reasons.append(f"{pricing_money(est.get('uninsured_loss'))} over policy limits")
        reasons.append(cat)
        # urgency inside a tier: more people, worse damage, more dangerous, more money at stake
        score = (10 - tier) * 1000 + min(occ, 9) * 60 + float(a.get("damage_percent") or 0) * 3 + safe * 40 \
            + min(float(est.get("uninsured_loss") or est.get("net_estimate") or 0) / 20000, 50)
        homes.append({
            "parcel_id": pid, "address": p["address"].split(",")[0], "tier": tier, "tier_label": TIERS[tier],
            "score": round(score, 1), "reasons": reasons, "damage_category": cat,
            "damage_percent": a.get("damage_percent"), "safety": safe,
            "occupants_on_file": p.get("occupants_on_file"), "pets_on_file": p.get("pets_on_file"),
            "people_seen": bool(seen or open_alerts), "covered": est.get("covered", True) if est.get("status") == "ok" else None,
            "net_estimate": est.get("net_estimate"), "uninsured_loss": est.get("uninsured_loss"),
            "checked_at": a.get("_timestamp"),
        })
    homes.sort(key=lambda h: (h["tier"], -h["score"]))
    counts = {}
    for h in homes:
        counts[h["tier_label"]] = counts.get(h["tier_label"], 0) + 1
    return {"homes": homes, "unchecked": unchecked, "counts": counts,
            "checked": len(homes), "total": len(homes) + len(unchecked)}


def pricing_money(v) -> str:
    try:
        return f"${float(v):,.0f}"
    except (TypeError, ValueError):
        return "-"
