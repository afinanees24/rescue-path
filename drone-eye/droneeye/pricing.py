"""First-pass loss estimate for an adjuster, per disaster type. Every number here is a configurable assumption,
not an actuarial model; the point is a fast triage figure the adjuster then verifies.

  wildfire, hurricane -> paid by the homeowners policy (hurricane uses a % wind deductible)
  flood               -> NOT covered by homeowners policies; paid only by a separate flood policy (e.g. NFIP),
                         so a home with no flood policy shows its loss as uninsured
"""
from __future__ import annotations

import os

REBUILD_COST_PER_SQFT = float(os.environ.get("DRONEEYE_COST_PER_SQFT", "450"))   # LA-area rebuild assumption
HURRICANE_DEDUCTIBLE_PCT = float(os.environ.get("DRONEEYE_HURRICANE_DED_PCT", "2"))  # % of dwelling coverage
TREE_REMOVAL = 1000   # typical homeowners allowance per claim for a tree on the house

CATEGORIES = {
    "No Damage":            (0, 0),
    "Affected (1-9%)":      (1, 9),
    "Minor (10-25%)":       (10, 25),
    "Major (26-50%)":       (26, 50),
    "Destroyed (>50%)":     (51, 100),
    "Unknown":              (None, None),
}
# share of belongings assumed lost at each category
CONTENTS_LOSS = {
    "wildfire":  {"No Damage": 0.0, "Affected (1-9%)": 0.05, "Minor (10-25%)": 0.2, "Major (26-50%)": 0.6, "Destroyed (>50%)": 1.0},
    "hurricane": {"No Damage": 0.0, "Affected (1-9%)": 0.02, "Minor (10-25%)": 0.10, "Major (26-50%)": 0.40, "Destroyed (>50%)": 1.0},
}
SEVERITY = {"none": 0.0, "minor": 0.15, "moderate": 0.4, "severe": 0.75, "destroyed": 1.0}

# Approximate depth-damage curves (feet of water above ground -> % of value damaged), one-story home, no basement.
FLOOD_BUILDING = [(0, 0), (0.5, 8), (1, 13), (2, 20), (3, 26), (4, 31), (5, 36), (6, 40), (8, 47), (10, 52), (15, 60)]
FLOOD_CONTENTS = [(0, 0), (0.5, 10), (1, 20), (2, 30), (3, 38), (4, 45), (6, 55), (8, 62), (10, 68)]
FLOOD_DEPTH_FOR_CAT = {"No Damage": 0, "Affected (1-9%)": 0.4, "Minor (10-25%)": 1.0, "Major (26-50%)": 3.0, "Destroyed (>50%)": 8.0}


def _money(x):
    return int(round(x / 100.0) * 100)


def _interp(curve, x):
    if x <= curve[0][0]:
        return curve[0][1]
    for (x0, y0), (x1, y1) in zip(curve, curve[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return curve[-1][1]


def _range(net, conf, cap):
    spread = 0.15 + 0.35 * (1 - conf)  # less confident -> wider range
    return _money(net * (1 - spread)), _money(min(net * (1 + spread), cap))


def estimate(parcel: dict | None, assessment: dict, hazard: str = "wildfire") -> dict | None:
    if not parcel or not assessment:
        return None
    cat = assessment.get("damage_category", "Unknown")
    lo, hi = CATEGORIES.get(cat, (None, None))
    if lo is None:
        return {"status": "insufficient view", "category": cat}
    if hazard == "flood":
        return _flood(parcel, assessment, cat)

    pct = assessment.get("damage_percent")
    pct = (lo + hi) / 2 if pct is None else min(max(float(pct), lo), hi)
    total_loss = cat.startswith("Destroyed")
    frac = 1.0 if total_loss else pct / 100.0

    sqft = parcel.get("sqft") or 1800
    replacement = sqft * REBUILD_COST_PER_SQFT
    pol = parcel.get("policy") or {}
    cov_a = pol.get("coverage_a_dwelling") or replacement
    cov_b = pol.get("coverage_b_other_structures") or 0.10 * cov_a
    cov_c = pol.get("coverage_c_contents") or 0.50 * cov_a
    deductible = pol.get("deductible") or 0
    ded_note = "policy deductible"
    if hazard == "hurricane":   # wind/hurricane deductibles are usually a % of dwelling coverage
        pct_ded = cov_a * HURRICANE_DEDUCTIBLE_PCT / 100
        if pct_ded > deductible:
            deductible, ded_note = pct_ded, f"{HURRICANE_DEDUCTIBLE_PCT:g}% hurricane deductible"

    dwelling = min(replacement * frac, cov_a)
    comps = assessment.get("components") or {}
    other_sev = [SEVERITY[comps[k]] for k in ("garage_outbuildings", "fences_walls") if comps.get(k) in SEVERITY]
    other = cov_b * (max(other_sev) if other_sev else frac * 0.5)
    contents = cov_c * CONTENTS_LOSS.get(hazard, CONTENTS_LOSS["wildfire"]).get(cat, 0.0)
    if hazard == "wildfire" and assessment.get("smoke_present") and contents < 0.1 * cov_c:
        contents = 0.1 * cov_c  # smoke/soot cleaning floor
    debris = 0.05 * cov_a if cat.startswith(("Major", "Destroyed")) else 0.0
    tree = TREE_REMOVAL if (hazard == "hurricane" and assessment.get("tree_on_structure")) else 0.0

    gross = dwelling + other + contents + debris + tree
    net = max(gross - deductible, 0)
    cap = max(cov_a + cov_b + cov_c + 0.05 * cov_a + tree - deductible, 0)
    low, high = _range(net, float(assessment.get("confidence") or 0.5), cap)
    lines = {
        "dwelling_cov_a": _money(dwelling),
        "other_structures_cov_b": _money(other),
        "contents_cov_c": _money(contents),
        "debris_removal": _money(debris),
    }
    labels = {"dwelling_cov_a": "Rebuilding the house", "other_structures_cov_b": "Garage and fence",
              "contents_cov_c": "Belongings inside", "debris_removal": "Clearing the debris"}
    if tree:
        lines["tree_removal"] = _money(tree)
        labels["tree_removal"] = "Removing the tree from the house"
    return {
        "status": "ok", "hazard": hazard, "category": cat, "covered": True,
        "paid_by": "Homeowners policy", "policy_number": pol.get("policy_number"),
        "damage_percent_used": round(pct, 1), "total_loss": total_loss,
        "assumptions": {"rebuild_cost_per_sqft": REBUILD_COST_PER_SQFT, "sqft": sqft},
        "replacement_cost": _money(replacement),
        "lines": lines, "line_labels": labels,
        "gross": _money(gross), "deductible": _money(deductible), "deductible_note": ded_note,
        "net_estimate": _money(net), "range_low": low, "range_high": high,
        "uninsured_loss": 0,
    }


def _flood(parcel, assessment, cat):
    """Flood: losses come from water depth. Homeowners policies exclude flood, so only a flood policy pays."""
    depth = assessment.get("water_depth_ft")
    depth_src = "AI estimate"
    if depth is None:
        depth, depth_src = FLOOD_DEPTH_FOR_CAT.get(cat, 0), f"typical for '{cat}'"
    depth = float(depth)
    sqft = parcel.get("sqft") or 1800
    replacement = sqft * REBUILD_COST_PER_SQFT
    contents_value = 0.5 * replacement
    destroyed = cat.startswith("Destroyed")
    b_frac = 1.0 if destroyed else _interp(FLOOD_BUILDING, depth) / 100
    c_frac = 1.0 if destroyed else _interp(FLOOD_CONTENTS, depth) / 100
    bldg_loss, cont_loss = replacement * b_frac, contents_value * c_frac
    total_loss = bldg_loss + cont_loss

    fp = parcel.get("flood_policy")
    conf = float(assessment.get("confidence") or 0.5)
    base = {
        "status": "ok", "hazard": "flood", "category": cat, "total_loss": destroyed,
        "water_depth_ft": round(depth, 1), "water_depth_source": depth_src,
        "assumptions": {"rebuild_cost_per_sqft": REBUILD_COST_PER_SQFT, "sqft": sqft},
        "replacement_cost": _money(replacement), "damage_percent_used": round(b_frac * 100, 1),
        "line_labels": {"building": "House (flood policy)", "contents": "Belongings (flood policy)"},
    }
    if not fp:
        low, high = _range(total_loss, conf, total_loss * 1.5)
        return {**base, "covered": False, "paid_by": "Not covered: no flood policy on file",
                "policy_number": None, "lines": {"building": 0, "contents": 0},
                "gross": _money(total_loss), "deductible": 0, "deductible_note": "",
                "net_estimate": 0, "range_low": 0, "range_high": 0,
                "uninsured_loss": _money(total_loss), "uninsured_low": low, "uninsured_high": high}

    b_pay = min(bldg_loss, fp.get("building", 250000))
    c_pay = min(cont_loss, fp.get("contents", 100000))
    ded = fp.get("deductible", 0)
    net = max(b_pay + c_pay - ded, 0)
    cap = max(fp.get("building", 250000) + fp.get("contents", 100000) - ded, 0)
    low, high = _range(net, conf, cap)
    return {**base, "covered": True, "paid_by": "Flood policy", "policy_number": fp.get("policy_number"),
            "lines": {"building": _money(b_pay), "contents": _money(c_pay)},
            "gross": _money(b_pay + c_pay), "deductible": _money(ded), "deductible_note": "flood deductible",
            "net_estimate": _money(net), "range_low": low, "range_high": high,
            "uninsured_loss": _money(max(total_loss - (b_pay + c_pay), 0))}
