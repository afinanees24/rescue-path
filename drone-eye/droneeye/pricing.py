"""First-pass loss estimate for an adjuster. Every number here is a configurable assumption,
not an actuarial model; the point is a fast triage figure the adjuster then verifies."""
from __future__ import annotations

import os

REBUILD_COST_PER_SQFT = float(os.environ.get("DRONEEYE_COST_PER_SQFT", "450"))  # LA-area rebuild assumption

# CAL FIRE DINS damage categories (the standard used for wildfire structure damage inspections)
CATEGORIES = {
    "No Damage":            (0, 0),
    "Affected (1-9%)":      (1, 9),
    "Minor (10-25%)":       (10, 25),
    "Major (26-50%)":       (26, 50),
    "Destroyed (>50%)":     (51, 100),
    "Unknown":              (None, None),
}
# share of contents assumed lost at each category (smoke/soot/heat included)
CONTENTS_LOSS = {"No Damage": 0.0, "Affected (1-9%)": 0.05, "Minor (10-25%)": 0.2,
                 "Major (26-50%)": 0.6, "Destroyed (>50%)": 1.0}
SEVERITY = {"none": 0.0, "minor": 0.15, "moderate": 0.4, "severe": 0.75, "destroyed": 1.0}


def _money(x):
    return int(round(x / 100.0) * 100)


def estimate(parcel: dict | None, assessment: dict) -> dict | None:
    if not parcel or not assessment:
        return None
    cat = assessment.get("damage_category", "Unknown")
    lo, hi = CATEGORIES.get(cat, (None, None))
    if lo is None:
        return {"status": "insufficient view", "category": cat}

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

    dwelling = min(replacement * frac, cov_a)

    comps = assessment.get("components") or {}
    other_sev = [SEVERITY[comps[k]] for k in ("garage_outbuildings", "fences_walls") if comps.get(k) in SEVERITY]
    other = cov_b * (max(other_sev) if other_sev else frac * 0.5)

    contents = cov_c * CONTENTS_LOSS.get(cat, 0.0)
    if assessment.get("smoke_present") and contents < 0.1 * cov_c:
        contents = 0.1 * cov_c  # smoke/soot cleaning floor
    debris = 0.05 * cov_a if cat.startswith(("Major", "Destroyed")) else 0.0

    gross = dwelling + other + contents + debris
    conf = float(assessment.get("confidence") or 0.5)
    spread = 0.15 + 0.35 * (1 - conf)  # less confident -> wider range
    net = max(gross - deductible, 0)
    max_payable = max(cov_a + cov_b + cov_c + 0.05 * cov_a - deductible, 0)
    return {
        "status": "ok",
        "category": cat,
        "damage_percent_used": round(pct, 1),
        "total_loss": total_loss,
        "assumptions": {"rebuild_cost_per_sqft": REBUILD_COST_PER_SQFT, "sqft": sqft},
        "replacement_cost": _money(replacement),
        "lines": {
            "dwelling_cov_a": _money(dwelling),
            "other_structures_cov_b": _money(other),
            "contents_cov_c": _money(contents),
            "debris_removal": _money(debris),
        },
        "gross": _money(gross),
        "deductible": deductible,
        "net_estimate": _money(net),
        "range_low": _money(net * (1 - spread)),
        "range_high": _money(min(net * (1 + spread), max_payable)),
    }
