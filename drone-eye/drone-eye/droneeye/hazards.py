"""Disaster types. Each one changes what the AI looks for, how the claim is priced, and how the dashboard draws it.
Add a new disaster by adding an entry here (and its visuals in static/house3d.js)."""

HAZARDS = {
    "wildfire": {
        "label": "Wildfire",
        "policy": "homeowners",
        "fire_detector": True,
        "prompt": """You are surveying homes after a WILDFIRE.
- Burned or charred = severe; collapsed or missing = destroyed. Smoke staining only = minor.
- Report active flames (active_fire) and smoke (smoke_present).
- Hazards to look for: downed power lines, unstable walls or chimneys, propane tanks, hot spots.""",
    },
    "hurricane": {
        "label": "Hurricane / wind",
        "policy": "homeowners",
        "fire_detector": False,
        "prompt": """You are surveying homes after a HURRICANE, TORNADO or other HIGH-WIND storm.
- Roof: a few missing shingles or a blue tarp = minor; large patches of shingles gone or roof deck exposed = moderate;
  big sections of roof torn off = severe; roof structure gone = destroyed.
- Walls: siding torn = minor; holes or a wall pushed in = severe; walls down = destroyed.
- Windows/doors blown in or boarded up count as damage. Garage doors pushed in = severe.
- Trees: branches down = minor; trees down = severe; a tree lying ON the house = set tree_on_structure true.
- Estimate roof_covering_missing_percent (0-100).
- active_fire is almost always false here. Note standing water if you see it, but rate WIND damage.
- Hazards to look for: downed power lines, trees on structure, debris, unstable roof, gas leaks.""",
    },
    "flood": {
        "label": "Flood",
        "policy": "flood",
        "fire_detector": False,
        "prompt": """You are surveying homes after a FLOOD.
- The single most important number is how high the water reached ABOVE THE GROUND at the house: water_depth_ft.
  Use clues: a waterline or mud line on walls, debris lines, how much of a door (~7 ft), window sill (~3 ft),
  car tire (~2 ft) or car roof (~5 ft) is or was under water. If water is still standing, estimate its depth.
- Categories: water only in the yard or below the floor = Affected; under 1.5 ft inside the living area = Minor;
  1.5 ft or more inside = Major; house moved off its foundation, collapsed or walls washed out = Destroyed.
- Components: rate water damage (walls soaked or stained, doors and windows, garage, cars under water).
- active_fire is almost always false here.
- Hazards to look for: standing water (electrocution risk), fast current, sewage, mold, undermined foundation.""",
    },
}

DEFAULT = "wildfire"


def get(name):
    return HAZARDS.get(name) or HAZARDS[DEFAULT]


def options():
    return [{"type": k, "label": v["label"]} for k, v in HAZARDS.items()]
