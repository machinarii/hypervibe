#!/usr/bin/env python3
"""Generate an SVG color-scheme mockup for the Bridge project.

Bridge = machinarii multi-agent orchestration surface.
Canvas = MacBook Pro 14" logical display (1512 x 982, 16:10).
Each card mocks the Bridge orchestration panel in a different combination
of colors sampled from the risograph print, so the new color scheme can
be judged across UI elements.
"""

# --- Palette sampled from the image -------------------------------------
COR = "#F9573C"  # coral / red-orange
BLU = "#2F39A6"  # cobalt blue
PUR = "#5E5570"  # muted purple (riso paper)
OLV = "#9A8A4E"  # olive gold
# derived neutrals to round out the schemes
INK = "#1E1B2E"  # near-black ink
CRM = "#F2EEE2"  # warm paper cream
DPUR = "#3A3447"  # deep purple

# --- Schemes: each applies the palette to different UI elements ----------
# keys: name, bg(card), border, head(title + dot), sub(muted), pill,
#       pillTxt(agent label), arrow(queued status), action(status text),
#       accent(running status / brand dot)
SCHEMES = [
    {"name": "Riso",     "bg": PUR,  "border": COR, "head": CRM, "sub": "#C9C3D4",
     "pill": BLU,  "pillTxt": CRM, "arrow": OLV, "action": CRM, "accent": COR},
    {"name": "Cobalt",   "bg": BLU,  "border": OLV, "head": CRM, "sub": "#AEB3E0",
     "pill": COR,  "pillTxt": CRM, "arrow": OLV, "action": CRM, "accent": COR},
    {"name": "Coral",    "bg": COR,  "border": INK, "head": INK, "sub": "#7A2418",
     "pill": BLU,  "pillTxt": CRM, "arrow": INK, "action": INK, "accent": BLU},
    {"name": "Paper",    "bg": CRM,  "border": OLV, "head": INK, "sub": "#8A8478",
     "pill": COR,  "pillTxt": CRM, "arrow": BLU, "action": INK, "accent": COR},
    {"name": "Midnight", "bg": INK,  "border": COR, "head": CRM, "sub": "#8E88A0",
     "pill": BLU,  "pillTxt": CRM, "arrow": OLV, "action": CRM, "accent": COR},
    {"name": "Olive",    "bg": OLV,  "border": INK, "head": INK, "sub": "#5C5436",
     "pill": COR,  "pillTxt": CRM, "arrow": BLU, "action": INK, "accent": BLU},
]

# agent rows: (name, status). status drives the indicator color.
AGENTS = [
    ("Planner",  "Running"),
    ("Explorer", "Running"),
    ("Coder",    "Queued"),
    ("Reviewer", "Idle"),
]

W, H = 1512, 982
MARGIN_X = 60
TOP = 96          # space for heading
GUTTER_X = 48
GUTTER_Y = 44
COLS, ROWS_N = 3, 2

card_w = (W - 2 * MARGIN_X - (COLS - 1) * GUTTER_X) / COLS
card_h = (H - TOP - 56 - (ROWS_N - 1) * GUTTER_Y) / ROWS_N


def status_color(status, s):
    return {"Running": s["accent"], "Queued": s["arrow"]}.get(status, s["sub"])


def card(x, y, s):
    p = 26
    w, h = card_w, card_h
    out = [f'<g transform="translate({x:.1f},{y:.1f})">']
    # card body with thin border + soft shadow
    out.append(
        f'<rect x="0" y="0" width="{w:.1f}" height="{h:.1f}" rx="20" ry="20" '
        f'fill="{s["bg"]}" stroke="{s["border"]}" stroke-width="1.5" '
        f'filter="url(#shadow)"/>')
    # header: brand dot + name + scheme tag
    out.append(f'<circle cx="{p+8}" cy="34" r="8" fill="{s["accent"]}"/>')
    out.append(
        f'<text x="{p+26}" y="40" font-family="Inter,Helvetica,Arial,sans-serif" '
        f'font-size="20" font-weight="700" fill="{s["head"]}">Bridge</text>')
    out.append(
        f'<text x="{w-p:.1f}" y="38" text-anchor="end" '
        f'font-family="Inter,Helvetica,Arial,sans-serif" font-size="12" '
        f'font-weight="600" letter-spacing="1.5" fill="{s["sub"]}">'
        f'{s["name"].upper()}</text>')
    # divider
    out.append(
        f'<line x1="{p}" y1="58" x2="{w-p:.1f}" y2="58" '
        f'stroke="{s["sub"]}" stroke-width="1" opacity="0.4"/>')
    # section label
    out.append(
        f'<text x="{p}" y="84" font-family="Inter,Helvetica,Arial,sans-serif" '
        f'font-size="11" font-weight="600" letter-spacing="1.5" '
        f'fill="{s["sub"]}">ACTIVE AGENTS</text>')
    # agent rows
    row_y = 100
    row_h = 46
    pill_w = 124
    for i, (name, status) in enumerate(AGENTS):
        ry = row_y + i * row_h
        cy = ry + row_h / 2
        # agent pill
        out.append(
            f'<rect x="{p}" y="{ry+6:.1f}" width="{pill_w}" height="{row_h-12}" '
            f'rx="{(row_h-12)/2:.1f}" fill="{s["pill"]}"/>')
        out.append(
            f'<text x="{p+pill_w/2:.1f}" y="{cy+4:.1f}" text-anchor="middle" '
            f'font-family="Inter,Helvetica,Arial,sans-serif" font-size="13" '
            f'font-weight="600" fill="{s["pillTxt"]}">{name}</text>')
        # status indicator dot
        sc = status_color(status, s)
        out.append(
            f'<circle cx="{p+pill_w+22:.1f}" cy="{cy:.1f}" r="5" fill="{sc}"/>')
        # status text
        out.append(
            f'<text x="{p+pill_w+38:.1f}" y="{cy+5:.1f}" '
            f'font-family="Inter,Helvetica,Arial,sans-serif" font-size="14" '
            f'fill="{s["action"]}">{status}</text>')
        # tiny task hint, right aligned
        hint = {"Running": "step 3/5", "Queued": "waiting", "Idle": "—"}[status]
        out.append(
            f'<text x="{w-p:.1f}" y="{cy+5:.1f}" text-anchor="end" '
            f'font-family="Inter,Helvetica,Arial,sans-serif" font-size="12" '
            f'fill="{s["sub"]}">{hint}</text>')
    # footer orchestration status
    fy = h - 44
    out.append(
        f'<line x1="{p}" y1="{fy-12:.1f}" x2="{w-p:.1f}" y2="{fy-12:.1f}" '
        f'stroke="{s["sub"]}" stroke-width="1" opacity="0.4"/>')
    out.append(f'<circle cx="{p+6}" cy="{fy+10:.1f}" r="5" fill="{s["accent"]}"/>')
    out.append(
        f'<text x="{p+20}" y="{fy+15:.1f}" '
        f'font-family="Inter,Helvetica,Arial,sans-serif" font-size="13" '
        f'font-weight="500" fill="{s["head"]}">4 agents · 2 running</text>')
    out.append(
        f'<text x="{w-p:.1f}" y="{fy+15:.1f}" text-anchor="end" '
        f'font-family="Inter,Helvetica,Arial,sans-serif" font-size="12" '
        f'fill="{s["sub"]}">main · synced</text>')
    out.append('</g>')
    return "\n".join(out)


parts = []
parts.append(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'viewBox="0 0 {W} {H}" font-family="Inter,Helvetica,Arial,sans-serif">')
# defs: backdrop gradient + card shadow
parts.append('<defs>')
parts.append(
    '<linearGradient id="backdrop" x1="0" y1="0" x2="1" y2="1">'
    f'<stop offset="0" stop-color="{INK}"/>'
    f'<stop offset="1" stop-color="{DPUR}"/></linearGradient>')
parts.append(
    '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
    '<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000000" '
    'flood-opacity="0.28"/></filter>')
parts.append('</defs>')
# background = full MacBook display
parts.append(f'<rect width="{W}" height="{H}" fill="url(#backdrop)"/>')
# heading
parts.append(
    f'<text x="{MARGIN_X}" y="56" font-size="26" font-weight="700" '
    f'fill="{CRM}">Bridge — color scheme explorations</text>')
parts.append(
    f'<text x="{MARGIN_X}" y="78" font-size="14" fill="#9E98AC">'
    f'Multi-agent orchestration surface · palette sampled from print '
    f'(coral / cobalt / purple / olive) applied to different UI elements</text>')
# palette swatches top-right
sw_x = W - MARGIN_X - 4 * 34 + 4
for i, (name, c) in enumerate([("coral", COR), ("cobalt", BLU),
                                ("purple", PUR), ("olive", OLV)]):
    parts.append(
        f'<rect x="{sw_x + i*34}" y="40" width="26" height="26" rx="6" '
        f'fill="{c}" stroke="#FFFFFF" stroke-opacity="0.2"/>')

# cards grid
for idx, s in enumerate(SCHEMES):
    r, c = divmod(idx, COLS)
    x = MARGIN_X + c * (card_w + GUTTER_X)
    y = TOP + r * (card_h + GUTTER_Y)
    parts.append(card(x, y, s))

parts.append('</svg>')

with open("mockups/bridge-colors.svg", "w") as f:
    f.write("\n".join(parts))
print("wrote mockups/bridge-colors.svg")
