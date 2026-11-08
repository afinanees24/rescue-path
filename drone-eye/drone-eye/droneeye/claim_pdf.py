"""Claim-ready PDF: property, policy, AI damage rating, payout estimate, and the marked evidence photos.

build_claim_pdf(state, [parcel_id, ...]) -> bytes. One section per home; the survey PDF is several homes in one file.
"""
from __future__ import annotations

import datetime as dt
import io
import os
import re
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT, TA_RIGHT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (CondPageBreak, Flowable, Image, KeepTogether, PageBreak, Paragraph, SimpleDocTemplate,
                                Spacer, Table, TableStyle)

from . import hazards, pricing

INK = colors.HexColor("#1E221F")
MUTED = colors.HexColor("#6B6F6A")
LINE = colors.HexColor("#DADBD5")
SOFT = colors.HexColor("#F3F3EF")
LIME = colors.HexColor("#C6E632")
LVL = {"No Damage": "#4F8A5B", "Affected": "#C9A227", "Minor": "#E0A030", "Major": "#E07B39",
       "Destroyed": "#C8462F", "Unknown": "#9A9A94"}
SEV = {"none": "No damage", "minor": "Minor", "moderate": "Moderate", "severe": "Severe",
       "destroyed": "Destroyed", "not_visible": "Not visible"}
SEV_HEX = {"minor": "#C9A227", "moderate": "#E07B39", "severe": "#C8462F", "destroyed": "#8E1F1A", "none": "#4F8A5B"}
PART = {"roof": "Roof", "exterior_walls": "Exterior walls", "windows_doors": "Windows & doors",
        "structural_frame": "Structural frame", "garage_outbuildings": "Garage / outbuildings",
        "fences_walls": "Fences & site walls", "vehicles": "Vehicles", "landscaping_vegetation": "Landscaping & trees",
        "other": "Other"}

W, H = letter
M = 0.6 * inch
CW = W - 2 * M          # content width


def _t(x) -> str:
    """Text safe for the built-in PDF fonts and for reportlab's mini-markup."""
    s = "" if x is None else str(x)
    s = (s.replace("≤", "<=").replace("≥", ">=").replace("→", "->").replace("×", "x"))
    s = s.encode("cp1252", "replace").decode("cp1252")
    return escape(s)


def _money(v) -> str:
    try:
        return f"${float(v):,.0f}"
    except (TypeError, ValueError):
        return "-"


def _when(ts) -> str:
    if not ts:
        return "-"
    return dt.datetime.fromtimestamp(ts).strftime("%b %d, %Y  %I:%M:%S %p").replace(" 0", " ")


def _cat_color(cat: str) -> colors.Color:
    for k, v in LVL.items():
        if str(cat).startswith(k):
            return colors.HexColor(v)
    return colors.HexColor(LVL["Unknown"])


S = {
    "h1": ParagraphStyle("h1", fontName="Helvetica", fontSize=22, leading=26, textColor=INK),
    "h2": ParagraphStyle("h2", fontName="Helvetica-Bold", fontSize=11.5, leading=15, textColor=INK, spaceBefore=12, spaceAfter=5),
    "body": ParagraphStyle("body", fontName="Helvetica", fontSize=9.5, leading=13.5, textColor=INK),
    "small": ParagraphStyle("small", fontName="Helvetica", fontSize=8, leading=11, textColor=MUTED),
    "lab": ParagraphStyle("lab", fontName="Helvetica", fontSize=7.5, leading=10, textColor=MUTED),
    "val": ParagraphStyle("val", fontName="Helvetica", fontSize=9.5, leading=12.5, textColor=INK),
    "big": ParagraphStyle("big", fontName="Helvetica", fontSize=20, leading=24, textColor=INK),
    "bigr": ParagraphStyle("bigr", fontName="Helvetica", fontSize=20, leading=24, textColor=INK, alignment=TA_RIGHT),
    "cell": ParagraphStyle("cell", fontName="Helvetica", fontSize=9, leading=12, textColor=INK),
    "cellr": ParagraphStyle("cellr", fontName="Helvetica", fontSize=9, leading=12, textColor=INK, alignment=TA_RIGHT),
    "cellb": ParagraphStyle("cellb", fontName="Helvetica-Bold", fontSize=9.5, leading=12.5, textColor=INK),
    "cellbr": ParagraphStyle("cellbr", fontName="Helvetica-Bold", fontSize=9.5, leading=12.5, textColor=INK, alignment=TA_RIGHT),
    "lead": ParagraphStyle("lead", fontName="Helvetica", fontSize=12.5, leading=17, textColor=INK),
    "fact": ParagraphStyle("fact", fontName="Helvetica", fontSize=15, leading=19, textColor=INK, spaceBefore=1),
    "check": ParagraphStyle("check", fontName="Helvetica", fontSize=10, leading=15, textColor=INK, leftIndent=2),
    "cap": ParagraphStyle("cap", fontName="Helvetica", fontSize=8.5, leading=11.5, textColor=INK, alignment=TA_LEFT),
}


def _P(text, style="body"):
    return Paragraph(text, S[style])


def _kv_grid(pairs, cols=3):
    """Label / value cells in a grid."""
    cells = [[_P(_t(k).upper(), "lab"), _P(_t(v) if v not in (None, "") else "-", "val")] for k, v in pairs]
    rows, row = [], []
    for c in cells:
        row.append(c)
        if len(row) == cols:
            rows.append(row)
            row = []
    if row:
        row += [""] * (cols - len(row))
        rows.append(row)
    t = Table(rows, colWidths=[CW / cols] * cols)
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 7), ("TOPPADDING", (0, 0), (-1, -1), 0)]))
    return t


def _table(rows, widths, header=True, total_rows=()):
    t = Table(rows, colWidths=widths)
    st = [("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("LINEBELOW", (0, 0), (-1, -1), 0.5, LINE),
          ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
          ("LEFTPADDING", (0, 0), (-1, -1), 6), ("RIGHTPADDING", (0, 0), (-1, -1), 6)]
    if header:
        st += [("BACKGROUND", (0, 0), (-1, 0), SOFT), ("LINEBELOW", (0, 0), (-1, 0), 0.8, INK)]
    for r in total_rows:
        st += [("LINEABOVE", (0, r), (-1, r), 0.8, INK), ("BACKGROUND", (0, r), (-1, r), SOFT)]
    t.setStyle(TableStyle(st))
    return t


def _photo(path, max_w, max_h):
    try:
        from reportlab.lib.utils import ImageReader
        iw, ih = ImageReader(path).getSize()
    except Exception:
        return None
    sc = min(max_w / iw, max_h / ih)
    img = Image(path, width=iw * sc, height=ih * sc)
    img.hAlign = "LEFT"
    return img


def _file(state, url):
    if not url:
        return None
    p = os.path.join(state.snapshot_dir, os.path.basename(url))
    return p if os.path.exists(p) else None


def _findings(r):
    out = []
    for g in r.get("damage_regions") or []:
        sev = g.get("severity", "")
        note = f" - {_t(g.get('note'))}" if g.get("note") else ""
        out.append((SEV_HEX.get(sev, "#6B6F6A"),
                    f"<b>{_t(PART.get(g.get('part'), g.get('part', 'Area')))}</b>: {_t(SEV.get(sev, sev))}{note}"))
    for d in r.get("_detections") or []:
        out.append(("#2F6FDB" if d.get("kind") == "life" else "#E8590C",
                    f"Onboard detector: {_t(d.get('label'))} ({float(d.get('conf') or 0):.0%})"))
    return out


def _marked(items, width, style="cap", shape="square"):
    """Rows of (colour, text) with a drawn marker; works in every PDF viewer (no symbol fonts)."""
    t = Table([[Dot(c, shape=shape), _P(x, style)] for c, x in items], colWidths=[12, width - 12])
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                           ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("TOPPADDING", (0, 0), (-1, -1), 1),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]))
    return t


def _evidence(state, pid, best, limit):
    """The photo the rating came from first, then photos the user took, then the newest automatic ones."""
    hist = [r for r in (state.assessments.get(pid) or []) if r.get("_snapshot")]
    hist = [r for r in hist if not str(r.get("damage_category", "")).startswith("Unknown")] or hist
    picks = []
    if best is not None and best.get("_snapshot"):
        picks.append(best)
    for r in sorted((r for r in hist if r.get("_manual")), key=lambda r: -r.get("_timestamp", 0)):
        if r is not best:
            picks.append(r)
    for r in sorted((r for r in hist if not r.get("_manual")), key=lambda r: -r.get("_timestamp", 0)):
        if r is not best:
            picks.append(r)
    return picks[:limit]


# ---------------------------------------------------------------- small drawings
LEVELS = [("No Damage", "No damage"), ("Affected", "Affected"), ("Minor", "Minor"), ("Major", "Major"), ("Destroyed", "Destroyed")]
SEV_LVL = {"none": 0, "minor": 1, "moderate": 2, "severe": 3, "destroyed": 4}
SAFETY = [("Safe to approach", "#4F8A5B"), ("Use caution", "#C9A227"), ("Danger", "#E07B39"), ("Keep out", "#C8462F")]


class DamageScale(Flowable):
    """The 5-step FEMA / CAL FIRE scale with the home's rating highlighted."""
    def __init__(self, cat, width, height=34):
        super().__init__()
        self.cat, self.width, self.height = str(cat), width, height

    def draw(self):
        c, n, gap = self.canv, len(LEVELS), 3
        sw = (self.width - gap * (n - 1)) / n
        cur = next((i for i, (k, _) in enumerate(LEVELS) if self.cat.startswith(k)), -1)
        for i, (k, label) in enumerate(LEVELS):
            x = i * (sw + gap)
            on = i == cur
            c.setFillColor(colors.HexColor(LVL[k]) if on else colors.HexColor("#E6E6E0"))
            c.roundRect(x, 14, sw, 12 if on else 8, 2.5, stroke=0, fill=1)
            c.setFillColor(INK if on else MUTED)
            c.setFont("Helvetica-Bold" if on else "Helvetica", 7.5)
            c.drawCentredString(x + sw / 2, 3, label)
            if on:
                c.setFillColor(INK)
                p = c.beginPath(); p.moveTo(x + sw / 2 - 4, self.height); p.lineTo(x + sw / 2 + 4, self.height)
                p.lineTo(x + sw / 2, self.height - 5); p.close(); c.drawPath(p, stroke=0, fill=1)


class SevBar(Flowable):
    """4 small blocks filled up to the part's severity."""
    def __init__(self, sev, width=90, height=10):
        super().__init__()
        self.sev, self.width, self.height = sev, width, height

    def draw(self):
        c = self.canv
        lvl = SEV_LVL.get(self.sev, -1)
        col = colors.HexColor(SEV_HEX.get(self.sev, "#9A9A94"))
        bw = (self.width - 9) / 4
        for i in range(4):
            c.setFillColor(col if i < lvl else colors.HexColor("#E6E6E0"))
            if self.sev == "not_visible":
                c.setFillColor(colors.HexColor("#F1F1EC"))
            c.roundRect(i * (bw + 3), 1, bw, self.height - 2, 1.5, stroke=0, fill=1)


class Dot(Flowable):
    """Small coloured circle or square drawn as a shape."""
    def __init__(self, color, size=7, shape="circle"):
        super().__init__()
        self.color = colors.HexColor(color) if isinstance(color, str) else color
        self.size, self.shape = size, shape
        self.width, self.height = size + 2, size + 3

    def draw(self):
        c = self.canv
        c.setFillColor(self.color)
        if self.shape == "square":
            c.roundRect(0, 2, self.size, self.size, 1.2, stroke=0, fill=1)
        else:
            c.circle(self.size / 2, self.size / 2 + 2, self.size / 2, stroke=0, fill=1)


class Box(Flowable):
    """Empty tick box for the adjuster to fill in by hand."""
    def __init__(self, size=10):
        super().__init__()
        self.width = self.height = size

    def draw(self):
        self.canv.setStrokeColor(INK)
        self.canv.setLineWidth(0.8)
        self.canv.roundRect(0, 0, self.width, self.height, 1.5, stroke=1, fill=0)


class RangeBar(Flowable):
    """Low - high band with the estimate marked."""
    def __init__(self, low, mid, high, width, height=34, color="#1E221F"):
        super().__init__()
        self.low, self.mid, self.high, self.width, self.height, self.color = low, mid, high, width, height, color

    def draw(self):
        c = self.canv
        lo, hi, mid = float(self.low or 0), float(self.high or 0), float(self.mid or 0)
        pad = 4
        c.setFillColor(colors.HexColor("#E6E6E0"))
        c.roundRect(pad, 16, self.width - 2 * pad, 6, 3, stroke=0, fill=1)
        if hi > lo:
            x = pad + (self.width - 2 * pad) * min(max((mid - lo) / (hi - lo), 0), 1)
        else:
            x = self.width / 2
        c.setFillColor(colors.HexColor(self.color))
        c.circle(x, 19, 5.5, stroke=0, fill=1)
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 7.5)
        c.drawString(pad, 4, f"Low {_money(lo)}")
        c.drawRightString(self.width - pad, 4, f"High {_money(hi)}")


def _safety(a, hazard):
    from .triage import safety_level
    return safety_level(a, hazard)


def _bottom_line(a, est, hazard):
    cat = str(a.get("damage_category", ""))
    lead = {"Destroyed": "This home looks like a total loss.", "Major": "This home has major damage.",
            "Minor": "This home has minor damage.", "Affected": "This home has light, mostly surface damage.",
            "No Damage": "No damage was seen on this home."}
    s = next((v for k, v in lead.items() if cat.startswith(k)), "The damage could not be rated.")
    if est.get("status") != "ok":
        return s + " Not enough of the home was visible to estimate a payout."
    if not est.get("covered", True):
        return (s + f" It is <b>not covered</b> ({_t(est.get('paid_by', '').split(':')[-1].strip())}); "
                f"the estimated uninsured loss is <b>{_money(est.get('uninsured_loss'))}</b>.")
    ded = f", after the {_money(est.get('deductible'))} {_t(est.get('deductible_note') or 'deductible')}" if est.get("deductible") else ""
    return (s + f" Estimated payout <b>{_money(est.get('net_estimate'))}</b> from the {_t(str(est.get('paid_by', '')).lower())}{ded}"
            f" (likely {_money(est.get('range_low'))} to {_money(est.get('range_high'))}).")


def _people(state, pid, a, p):
    alerts = [x for x in state.alerts if x.get("parcel_id") == pid and x.get("kind") == "life"]
    seen = list(a.get("signs_of_life") or []) + [f"{x['label']} ({x['source']})" for x in alerts]
    on_file = p.get("occupants_on_file")
    if seen:
        return "#C8462F", "Possible people or pets", "; ".join(seen)
    tail = f"{on_file} occupants, {p.get('pets_on_file') or 0} pets on file" if on_file is not None else "no occupancy on file"
    return "#4F8A5B", "No one seen", tail


def _fact(label, value, sub="", color=None):
    if color:
        v = Table([[Dot(color, 9), _P(value, "fact")]], colWidths=[16, None])
        v.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                               ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("TOPPADDING", (0, 0), (-1, -1), 1),
                               ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
        v.hAlign = "LEFT"
    else:
        v = _P(value, "fact")
    out = [_P(_t(label).upper(), "lab"), v]
    if sub:
        out.append(_P(sub, "small"))
    return out


# ---------------------------------------------------------------- one home
def _home(state, pid, hazard, report_no, story, photo_limit, prepared_for=""):
    p = state.parcels.get(pid)
    a = state.best(pid)
    if not p or not a:
        return False
    hz = hazards.get(hazard)
    est = pricing.estimate(p, a, hazard) or {}
    pol = p.get("policy") or {}
    fpol = p.get("flood_policy") or {}
    cat = a.get("damage_category", "Unknown")
    conf = float(a.get("confidence") or 0)
    covered = est.get("status") == "ok" and est.get("covered", True)

    # ---- 1. title + the one-sentence answer
    story.append(_P(_t(p["address"].split(",")[0]), "h1"))
    story.append(_P(_t(", ".join(p["address"].split(",")[1:]).strip())
                    + f" &nbsp;&middot;&nbsp; Policy {_t(pol.get('policy_number') or 'none on file')}"
                    + f" &nbsp;&middot;&nbsp; {_t(hz['label'])}"
                    + (f" &nbsp;&middot;&nbsp; Prepared for {_t(prepared_for)}" if prepared_for else ""), "small"))
    story.append(Spacer(1, 10))
    bl = Table([[_P(_bottom_line(a, est, hazard), "lead")]], colWidths=[CW])
    bl.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), SOFT), ("LINEBEFORE", (0, 0), (0, -1), 3, _cat_color(cat)),
                            ("LEFTPADDING", (0, 0), (-1, -1), 12), ("TOPPADDING", (0, 0), (-1, -1), 9),
                            ("BOTTOMPADDING", (0, 0), (-1, -1), 10)]))
    story.append(bl)
    story.append(Spacer(1, 12))

    # ---- 2. at a glance: photo on the left, four answers on the right
    left_w, right_w = CW * 0.52, CW * 0.48
    path = _file(state, a.get("_snapshot_marked")) or _file(state, a.get("_snapshot"))
    pic = path and _photo(path, left_w - 10, 2.75 * inch)
    left = [pic, Spacer(1, 3), _P(f"Photo the rating is based on &middot; {_t(_when(a.get('_timestamp')))}", "small")] if pic \
        else [_P("No photo saved for this rating.", "small")]

    si = _safety(a, hazard)
    pc, pw, psub = _people(state, pid, a, p)
    if covered:
        pay = _fact("Estimated payout", _money(est.get("net_estimate")), _t(est.get("paid_by")))
        pay.append(RangeBar(est.get("range_low"), est.get("net_estimate"), est.get("range_high"), right_w - 16))
    elif est.get("status") == "ok":
        pay = _fact("Not covered - uninsured loss", _money(est.get("uninsured_loss")), _t(est.get("paid_by")), "#C8462F")
    else:
        pay = _fact("Estimated payout", "-", "Not enough of the home was visible")
    right = Table([
        [_fact("Damage rating", f"<b>{_t(cat)}</b>",
               f"About {float(a.get('damage_percent') or 0):.0f}% of the home &middot; AI confidence {conf:.0%}")
         + [Spacer(1, 4), DamageScale(cat, right_w - 16)]],
        [pay],
        [_fact("Safe to enter?", SAFETY[si][0], " &middot; ".join(_t(h) for h in (a.get("hazards") or [])[:3]) or "No hazards seen",
               SAFETY[si][1])],
        [_fact("People", pw, _t(psub), pc)],
    ], colWidths=[right_w])
    right.setStyle(TableStyle([("LEFTPADDING", (0, 0), (-1, -1), 8), ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                               ("TOPPADDING", (0, 0), (-1, -1), 7), ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
                               ("LINEBELOW", (0, 0), (-1, -2), 0.5, LINE), ("BOX", (0, 0), (-1, -1), 0.6, LINE)]))
    glance = Table([[left, right]], colWidths=[left_w, right_w])
    glance.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                                ("RIGHTPADDING", (0, 0), (-1, -1), 0)]))
    story.append(glance)

    # ---- 3. damage by part
    comps = a.get("components") or {}
    rows = []
    for k, label in PART.items():
        if k in comps:
            v = comps[k]
            rows.append([_P(_t(label), "cell"), SevBar(v, width=(CW - 14) / 2 * 0.30 - 10), _P(_t(SEV.get(v, v)), "cell")])
    if rows:
        story.append(_P("Damage by part of the home", "h2"))
        half = (len(rows) + 1) // 2
        pairs = [rows[i] + [""] + (rows[i + half] if i + half < len(rows) else ["", "", ""]) for i in range(half)]
        cw = (CW - 14) / 2
        t = Table(pairs, colWidths=[cw * 0.44, cw * 0.30, cw * 0.26, 14, cw * 0.44, cw * 0.30, cw * 0.26])
        t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                               ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
                               ("LINEBELOW", (0, 0), (2, -1), 0.4, LINE), ("LINEBELOW", (4, 0), (6, -1), 0.4, LINE)]))
        story.append(t)
    if a.get("adjuster_summary"):
        story.append(Spacer(1, 8))
        story.append(_P(f"<b>What the AI saw:</b> {_t(a.get('adjuster_summary'))}"))

    # ---- 4. how the payout adds up
    story.append(PageBreak())
    if est.get("status") == "ok":
        story.append(_P("How the payout adds up", "h2"))
        if not covered:
            rows = [[_P("Estimated loss to the home and belongings", "cell"), _P(_money(est.get("gross")), "cellr")],
                    [_P(_t(est.get("paid_by")), "cell"), _P("$0", "cellr")],
                    [_P("Estimated uninsured loss", "cellb"), _P(_money(est.get("uninsured_loss")), "cellbr")],
                    [_P("Likely range", "cell"),
                     _P(f"{_money(est.get('uninsured_low'))} to {_money(est.get('uninsured_high'))}", "cellr")]]
            story.append(_table(rows, [CW * 0.7, CW * 0.3], header=False, total_rows=[2]))
            story.append(Spacer(1, 4))
            story.append(_P("Homeowners policies exclude flood. With no flood policy on file, no payout is expected for this "
                            "loss; the amount is shown for the owner and for disaster-assistance programs.", "small"))
        else:
            labels = est.get("line_labels") or {"building": "Building (flood policy)", "contents": "Belongings (flood policy)"}
            rows = []
            for k, v in (est.get("lines") or {}).items():
                rows.append([_P(_t(labels.get(k, k.replace("_", " ").capitalize())), "cell"), _P(_money(v), "cellr")])
            rows.append([_P("Total covered damage", "cellb"), _P(_money(est.get("gross")), "cellbr")])
            ded = est.get("deductible_note") or "deductible"
            rows.append([_P(_t("Minus the " + ded), "cell"), _P("- " + _money(est.get("deductible")), "cellr")])
            rows.append([_P("Estimated payout", "cellb"), _P(_money(est.get("net_estimate")), "cellbr")])
            n = len(rows)
            if est.get("uninsured_loss"):
                rows.append([_P("Damage above the policy limits (not paid)", "cell"), _P(_money(est.get("uninsured_loss")), "cellr")])
            story.append(_table(rows, [CW * 0.7, CW * 0.3], header=False, total_rows=[n - 3, n - 1]))
            asm = est.get("assumptions") or {}
            if asm:
                story.append(Spacer(1, 4))
                story.append(_P(f"Rebuild cost: {_money(asm.get('rebuild_cost_per_sqft'))} per sq ft x {asm.get('sqft'):,} sq ft "
                                f"= {_money(est.get('replacement_cost'))}. Damage share used: {est.get('damage_percent_used', '-')}%. "
                                f"The likely range is wider when the AI is less sure.", "small"))

    # ---- 5. property and policy
    story.append(_P("Property and policy on file", "h2"))
    story.append(_kv_grid([
        ("Address", p["address"]), ("Parcel", pid), ("Year built", p.get("year_built")),
        ("Building", f"{p.get('structure_type', '-')}, {p.get('stories', '-')} story, "
                     + (f"{p.get('sqft'):,} sq ft" if p.get("sqft") else "")),
        ("Roof", p.get("roof_type")), ("Construction", p.get("construction")),
        ("Homeowners policy", pol.get("policy_number") or "None on file"),
        ("Dwelling coverage", _money(pol.get("coverage_a_dwelling")) if pol else "-"),
        ("Deductible", _money(pol.get("deductible")) if pol else "-"),
        ("Other structures", _money(pol.get("coverage_b_other_structures")) if pol else "-"),
        ("Belongings", _money(pol.get("coverage_c_contents")) if pol else "-"),
        ("Flood policy", (f"{fpol.get('policy_number')} ({_money(fpol.get('building'))} / {_money(fpol.get('contents'))})"
                          if fpol else "None on file")),
    ]))

    # ---- 6. inspection
    story.append(_P("Inspection", "h2"))
    extra = (("Active fire seen", "Yes" if a.get("active_fire") else "No") if hazard == "wildfire" else
             ("Water depth (est.)", f"{a['water_depth_ft']:.1f} ft" if a.get("water_depth_ft") is not None else "-")
             if hazard == "flood" else ("Tree on the house", "Yes" if a.get("tree_on_structure") else "No"))
    story.append(_kv_grid([
        ("Inspected", _when(a.get("_timestamp"))), ("Method", "Drone camera, AI-rated"),
        ("Rated by", "NVIDIA Nemotron" if "nemotron" in str(a.get("_engine")) else (a.get("_engine") or "-")),
        ("Photos taken", str(len([r for r in state.assessments.get(pid) or [] if r.get("_snapshot")]))),
        ("Location", f"{p['lat']:.5f}, {p['lon']:.5f}"), extra,
    ]))

    # ---- 7. next steps as a checklist
    steps = list(a.get("recommended_actions") or [])
    if si >= 2:
        steps.insert(0, "Do not enter until the site is declared safe")
    if pc == "#C8462F":
        steps.insert(0, "Confirm with responders that everyone is accounted for")
    steps += ["Verify the damage on site and confirm the rating", "Attach contractor estimates before settling"]
    seen = set()
    steps = [s for s in steps if not (s.lower() in seen or seen.add(s.lower()))]
    story.append(_P("Next steps for the adjuster", "h2"))
    ck = Table([[Box(), _P(_t(x), "check")] for x in steps[:7]], colWidths=[18, CW - 18])
    ck.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                            ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 3)]))
    story.append(ck)

    # ---- 8. photos
    picks = _evidence(state, pid, a, photo_limit)
    if picks:
        story.append(PageBreak())
        story.append(_P(f"Photos &middot; {_t(p['address'].split(',')[0])}", "h2"))
        story.append(_P("Each frame is exactly what the drone camera saw when the AI rated the home. Coloured boxes mark the "
                        "damage it found (yellow minor, orange moderate, red severe, dark red destroyed); blue marks a person "
                        "or animal and orange-filled marks fire from the onboard detector.", "small"))
        story.append(Spacer(1, 8))
        for i, r in enumerate(picks):
            fp = _file(state, r.get("_snapshot_marked")) or _file(state, r.get("_snapshot"))
            img = fp and _photo(fp, CW * 0.58, 3.0 * inch)
            if not img:
                continue
            tag = ("Taken by the operator" if r.get("_manual") else "Taken automatically") + (" &middot; <b>used for the rating</b>" if r is a else "")
            cap = [_P(f"<b>Photo {i + 1}</b>", "cap"), _P(tag, "small"), _P(_t(_when(r.get("_timestamp"))), "small"), Spacer(1, 5),
                   _P(f"<b>{_t(r.get('damage_category'))}</b> &middot; {float(r.get('damage_percent') or 0):.0f}% "
                      f"&middot; confidence {float(r.get('confidence') or 0):.0%}", "cap"), Spacer(1, 4)]
            fnd = _findings(r)
            cap += [_marked(fnd, CW * 0.4 - 12)] if fnd else [_P("Whole home rated; no specific areas marked.", "small")]
            cap += [Spacer(1, 4), _P(f"File: {_t(os.path.basename(fp))}", "small")]
            row = Table([[img, cap]], colWidths=[CW * 0.6, CW * 0.4])
            row.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                                     ("LEFTPADDING", (1, 0), (1, 0), 10), ("BOTTOMPADDING", (0, 0), (-1, -1), 12),
                                     ("LINEBELOW", (0, 0), (-1, -1), 0.5, LINE)]))
            story.append(KeepTogether([row, Spacer(1, 10)]))
    return True


def build_claim_pdf(state, parcel_ids, prepared_for="Claims adjuster", photo_limit=6) -> bytes | None:
    hazard = state.hazard
    now = dt.datetime.now()
    report_no = f"DE-{now:%Y%m%d-%H%M}" + (f"-{parcel_ids[0].split('-')[-1]}" if len(parcel_ids) == 1 else "-SURVEY")
    buf = io.BytesIO()

    def chrome(c, doc):
        c.saveState()
        c.setFillColor(INK)
        c.rect(0, H - 0.52 * inch, W, 0.52 * inch, stroke=0, fill=1)
        c.setFillColor(LIME)
        c.circle(M + 4, H - 0.26 * inch, 4, stroke=0, fill=1)
        c.setFillColor(colors.white)
        c.setFont("Helvetica-Bold", 10.5)
        c.drawString(M + 14, H - 0.30 * inch, "Drone-Eye")
        c.setFont("Helvetica", 10.5)
        c.drawString(M + 72, H - 0.30 * inch, "Preliminary Property Damage Report")
        c.setFont("Helvetica", 8.5)
        c.drawRightString(W - M, H - 0.30 * inch, f"Report {report_no}")
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 7.2)
        c.drawString(M, 0.42 * inch, f"Prepared for: {prepared_for}  |  Generated {now:%b %d, %Y %I:%M %p}  |  "
                                     "AI-assisted preliminary estimate - subject to adjuster verification")
        c.drawRightString(W - M, 0.42 * inch, f"Page {doc.page}")
        c.restoreState()

    doc = SimpleDocTemplate(buf, pagesize=letter, leftMargin=M, rightMargin=M, topMargin=0.85 * inch,
                            bottomMargin=0.75 * inch, title=f"Drone-Eye damage report {report_no}",
                            author="Drone-Eye", subject="Preliminary property damage report")
    story = []
    homes = [pid for pid in parcel_ids if state.best(pid)]
    if not homes:
        return None

    # cover strip (survey only; a single-home report starts straight with the answer)
    if len(homes) > 1:
        story.append(_kv_grid([("Report number", report_no), ("Prepared for", prepared_for),
                               ("Date", now.strftime("%b %d, %Y")),
                               ("Peril", hazards.get(hazard)["label"]), ("Homes in this report", str(len(homes))),
                               ("Source", "Drone-Eye aerial survey")]))
        rows = [[_P("<b>Address</b>", "cell"), _P("<b>Rating</b>", "cell"), _P("<b>Est. payout</b>", "cellr")]]
        tot = 0.0
        for pid in homes:
            a = state.best(pid)
            e = pricing.estimate(state.parcels.get(pid), a, hazard) or {}
            tot += float(e.get("net_estimate") or 0)
            rows.append([_P(_t(state.parcels.get(pid)["address"].split(",")[0]), "cell"),
                         _marked([(_cat_color(a.get("damage_category")), _t(a.get("damage_category")))], CW * 0.3 - 12, "cell"),
                         _P(_money(e.get("net_estimate")) if e.get("status") == "ok" else "-", "cellr")])
        rows.append([_P("Total", "cellb"), _P("", "cell"), _P(_money(tot), "cellbr")])
        story.append(_P("Survey summary", "h2"))
        story.append(_table(rows, [CW * 0.45, CW * 0.3, CW * 0.25], total_rows=[len(rows) - 1]))
        story.append(PageBreak())
    else:
        story.append(Spacer(1, 4))

    for n, pid in enumerate(homes):
        if n:
            story.append(PageBreak())
        _home(state, pid, hazard, report_no, story, photo_limit, prepared_for)

    # method + sign-off
    story.append(CondPageBreak(2.1 * inch))
    story.append(_P("How this estimate was made", "h2"))
    story.append(_P("A drone camera captured the property. An AI vision model (NVIDIA Nemotron) rated each part of the home "
                    "on the CAL FIRE DINS / FEMA damage scale and marked where the damage is. The payout is the rated damage "
                    "share applied to the rebuild cost and policy coverages on file, minus the deductible; the range widens "
                    "when the AI is less sure. Every pricing rate is a stated assumption in the Drone-Eye source "
                    "(droneeye/pricing.py).", "small"))
    story.append(Spacer(1, 6))
    story.append(_P("<b>This is a preliminary, AI-assisted estimate, not a coverage decision or settlement offer.</b> "
                    "It is meant to help an adjuster prioritise and prepare; final amounts require on-site verification, "
                    "the full policy terms, and contractor estimates. Property and policy data in this demo are fictional.", "small"))
    story.append(Spacer(1, 22))
    sig = Table([["", "", ""], [_P("Reviewing adjuster", "lab"), _P("Signature", "lab"), _P("Date", "lab")]],
                colWidths=[CW * 0.4, CW * 0.4, CW * 0.2], rowHeights=[22, None])
    sig.setStyle(TableStyle([("LINEBELOW", (0, 0), (-1, 0), 0.6, INK), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                             ("RIGHTPADDING", (0, 0), (-1, -1), 14)]))
    story.append(sig)

    doc.build(story, onFirstPage=chrome, onLaterPages=chrome)
    return buf.getvalue()
