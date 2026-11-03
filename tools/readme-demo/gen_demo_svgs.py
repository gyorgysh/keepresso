#!/usr/bin/env python3
"""Generate the animated README demo cards (docs/assets/demo_*.svg).

Each card is a self-contained SVG: the dark menu-bar popover (tokens from the
keepresso.com hero, dark theme) driven by CSS keyframes. No script, no external
fonts, so GitHub renders it through a plain <img>.

Every scene is a fixed loop of L seconds. Visual state is described as time
windows and keyframe points in seconds, converted to percentages here, so the
whole timeline reads top to bottom in each scene function.

    python3 tools/readme-demo/gen_demo_svgs.py
"""

from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "docs" / "assets"

W, H = 360, 480
P = 118  # popover top
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"

# Dark popover tokens (home.jsx .kd-menu, dark theme)
BG = "#1f1e20"
BORDER = "rgba(255,255,255,.14)"
HEAD = "rgba(255,255,255,.07)"
STRONG = "#ffffff"
TEXT = "#ededf0"
SUB = "#a8a8ad"
DIM = "#8e8e93"
HAIR = "rgba(255,255,255,.09)"
CTL = "rgba(255,255,255,.11)"
AMBER = "#eda158"
BTN = "#e2913f"
BTNTX = "#2e1c07"
SW_OFF = "#5b5b60"
SW_ON = "#e2913f"
CUP = "#e2a35c"
CREMA = "#fbe3c4"
CLAUDE = "#d97757"
MONOFG = "#f2f2f2"
GREEN = "#2fd158"
KICKER = "#d39a62"
HEADLINE = "#f6efe6"


class Scene:
    def __init__(self, L):
        self.L = L
        self.css = []
        self.n = 0

    def pct(self, t):
        return f"{max(0.0, min(100.0, t / self.L * 100)):.3f}%"

    def track(self, points, prop, ease="linear"):
        """points: [(t, value)] or [(t, value, ease)]. Returns a class name."""
        self.n += 1
        name = f"a{self.n}"
        pts = sorted(points, key=lambda p: p[0])
        if pts[0][0] > 0:
            pts.insert(0, (0, pts[0][1]))
        if pts[-1][0] < self.L:
            pts.append((self.L, pts[-1][1]))
        frames = []
        for p in pts:
            e = p[2] if len(p) > 2 else ease
            frames.append(f"{self.pct(p[0])}{{{prop(p[1])};animation-timing-function:{e}}}")
        self.css.append(f"@keyframes {name}{{{''.join(frames)}}}")
        self.css.append(f".{name}{{animation:{name} {self.L}s infinite}}")
        return name

    def vis(self, windows, fade=0.25):
        """Opacity 1 inside each (t0, t1) window. Fades out over the last
        fade/2 s before t1 and in over the first fade/2 s after t0, so two
        layers swapping at the same instant never overlap mid-fade."""
        L = self.L
        h = fade / 2
        pts = []
        for a, b in windows:
            if a <= 0:
                pts.append((0, 1))
            else:
                pts += [(a, 0), (a + h, 1)]
            if b >= L:
                pts.append((L, 1))
            else:
                pts += [(b - h, 1), (b, 0)]
        if not pts or pts[0][0] > 0:
            pts.insert(0, (0, 0))
        return self.track(pts, lambda v: f"opacity:{v}")

    def move(self, points):
        """points: [(t, x, y)], eased glide between stops."""
        glide = "cubic-bezier(.3,.7,.3,1)"
        return self.track([(t, (x, y), glide) for t, x, y in points],
                          lambda v: f"transform:translate({v[0]}px,{v[1]}px)")

    def scale(self, points):
        return self.track(points, lambda v: f"transform:scale({v})")

    def tap(self, times, depth=0.8, d=0.14, hold=0.12):
        """Cursor press dips at each click time."""
        pts = [(0, 1)]
        for t in times:
            pts += [(t - d, 1), (t, depth), (t + hold, depth), (t + hold + d, 1)]
        return self.scale(pts)


# ---------------------------------------------------------------- primitives

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=12.8, fill=TEXT, weight=400, anchor="start", cls=None, extra=""):
    c = f' class="{cls}"' if cls else ""
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}"'
            f' text-anchor="{anchor}"{c}{extra}>{s}</text>')


def g(inner, cls=None, extra=""):
    c = f' class="{cls}"' if cls else ""
    return f"<g{c}{extra}>{inner}</g>"


def cup(x, y, size, on_cls=None, off_cls=None, steam_cls=None, menubar=False):
    """Keepresso cup (64-unit grid). `on`/`off` classes crossfade the two looks."""
    s = size / 64
    if menubar:
        body, crema, line, steam = "#f2ede6", "#d98136", "#f2ede6", CUP
    else:
        body, crema, line, steam = CUP, CREMA, CUP, CUP
    steam_paths = ("M24 12c-2.6 3.2 2.6 5 0 9.5", "M32 9c-2.6 3.2 2.6 5 0 9.5",
                   "M40 12c-2.6 3.2 2.6 5 0 9.5")
    if menubar:
        steam_paths = ("M26 11c-2.6 3.2 2.6 5 0 9.5", "M35 9c-2.6 3.2 2.6 5 0 9.5")
    st = "".join(f'<path class="steam s{i + 1}" d="{d}" stroke="{steam}" stroke-width="3.2" '
                 f'stroke-linecap="round" fill="none"/>' for i, d in enumerate(steam_paths))
    on = (f'<path d="M16 28h28v10a9 9 0 0 1-9 9h-10a9 9 0 0 1-9-9V28Z" fill="{body}"/>'
          f'<rect x="20" y="31.5" width="20" height="3.4" rx="1.7" fill="{crema}"/>'
          f'<path d="M44 31.5h2.5a6 6 0 0 1 0 12H43" stroke="{line}" stroke-width="3.4" stroke-linecap="round" fill="none"/>'
          f'<path d="M15 52h30" stroke="{line}" stroke-width="3.6" stroke-linecap="round"/>')
    off_c = SUB
    off = (f'<path d="M16 28h28v10a9 9 0 0 1-9 9h-10a9 9 0 0 1-9-9V28Z" fill="none" stroke="{off_c}" stroke-width="3.2"/>'
           f'<path d="M44 31.5h2.5a6 6 0 0 1 0 12H43" stroke="{off_c}" stroke-width="3.4" stroke-linecap="round" fill="none"/>'
           f'<path d="M15 52h30" stroke="{off_c}" stroke-width="3.6" stroke-linecap="round"/>')
    parts = [g(st, steam_cls), g(on, on_cls)]
    if off_cls:
        parts.append(g(off, off_cls))
    return f'<g transform="translate({x} {y}) scale({s:.4f})">{"".join(parts)}</g>'


def check(cx, cy, cls=None):
    return g(f'<circle cx="{cx}" cy="{cy}" r="7.2" fill="{GREEN}"/>'
             f'<path d="M{cx - 3.2} {cy + 0.3} {cx - 1} {cy + 2.4}l4.2-4.6" fill="none" stroke="#fff" '
             f'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>', cls)


def ring(cx, cy, cls=None):
    return g(f'<circle cx="{cx}" cy="{cy}" r="6.4" fill="none" stroke="{DIM}" stroke-width="1.5"/>', cls)


def info(x, y):
    """Small (i) glyph, x/y = centre."""
    return (f'<g transform="translate({x - 6} {y - 6}) scale(.75)" fill="none" stroke="{DIM}" stroke-width="1.4" '
            f'stroke-linecap="round"><circle cx="8" cy="8" r="6.6"/><path d="M8 7.4v3.4M8 5.1v.1"/></g>')


def switch(sc, cy, on_windows, flips=()):
    """Toggle at the right edge. on_windows: when it is on. flips: knob slide times."""
    x = 284
    track_on = sc.vis(on_windows, fade=0.25)
    pts = []
    L = sc.L
    state0 = any(a <= 0 for a, _ in on_windows)
    pts.append((0, 15 if state0 else 0))
    for a, b in on_windows:
        if a > 0:
            pts += [(a, 0, "ease-in-out"), (a + 0.25, 15)]
        if b < L:
            pts += [(b, 15, "ease-in-out"), (b + 0.25, 0)]
    knob = sc.track(pts, lambda v: f"transform:translateX({v}px)")
    return (f'<rect x="{x}" y="{cy - 10.5}" width="36" height="21" rx="10.5" fill="{SW_OFF}"/>'
            f'<rect x="{x}" y="{cy - 10.5}" width="36" height="21" rx="10.5" fill="{SW_ON}" class="{track_on}"/>'
            f'<g class="{knob}"><circle cx="{x + 10.5}" cy="{cy}" r="8.5" fill="#fff" filter="url(#knob)"/></g>')


def segmented(y, manual):
    """The Automatic/Manual mode switch, centred, top edge at y."""
    x, w, h = 100, 160, 25
    half = w / 2
    sel_x = x + half if manual else x
    out = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{CTL}"/>'
           f'<rect x="{sel_x + 1.5}" y="{y + 1.5}" width="{half - 3}" height="{h - 3}" rx="6.5" fill="{SW_ON}"/>')
    for i, label in enumerate(("Automatic", "Manual")):
        on = (i == 1) == manual
        out += text(x + half * i + half / 2, y + 17, label, size=12.4, fill="#fff" if on else TEXT,
                    weight=600 if on else 500, anchor="middle")
    return out


# Drawn agent marks, ported from the site (SparkFrames.swift geometry).
def _ray(r):
    o = 6 * r
    w = o * 0.21
    hw = w / 2
    return "".join(f'<rect x="{-hw:.3f}" y="{-hw:.3f}" width="{o + hw:.3f}" height="{w:.3f}" rx="{hw:.3f}" '
                   f'transform="translate(6 6) rotate({a})"/>'
                   for a in (-90, -54, -18, 18, 54, 90, 126, 162, 198, 234))


def _petal(r):
    o = 6 * r
    inset = o * 0.32
    pw = o * 0.38
    cx = inset + (o - inset) / 2
    s = f'<circle cx="6" cy="6" r="{o * 0.17:.3f}"/>'
    s += "".join(f'<ellipse cx="{cx:.3f}" cy="0" rx="{(o - inset) / 2:.3f}" ry="{pw / 2:.3f}" '
                 f'transform="translate(6 6) rotate({a})"/>' for a in (-90, -30, 30, 90, 150, 210))
    return s


CLAUDE_FRAMES = [f'<circle cx="6" cy="6" r="{6 * 0.26:.3f}"/>', _ray(0.72), _ray(1), _ray(1), _ray(0.64),
                 f'<circle cx="6" cy="6" r="{6 * 0.22:.3f}"/>', _petal(0.8), _petal(1), _petal(1), _petal(0.62)]


def _dots(mask):
    step, dot, rx = 4, 2.48, 0.55
    inset = (step - dot) / 2
    return "".join(f'<rect x="{c * step + inset:.2f}" y="{r * step + inset:.2f}" width="{dot}" height="{dot}" rx="{rx}"/>'
                   for r, row in enumerate(mask) for c, ch in enumerate(row) if ch == "#")


CURSOR_FRAMES = [_dots(m) for m in (["..#", "..#", "##."], ["...", "#.#", "#.#"], ["#..", "#..", ".##"],
                                    ["#..", "##.", ".#."], ["##.", "##.", "..#"], [".#.", "###", "#.#"],
                                    [".##", ".##", "#.."], ["..#", ".##", ".#."])]

SPARK_CSS = (
    ".sc>g{opacity:0;animation:1.3s linear infinite}"
    + "".join(f".sc>g:nth-child({i + 1}){{animation-name:c{i + 1}}}" for i in range(10))
    + "".join(f"@keyframes c{i + 1}{{0%,{i * 10}%{{opacity:0}}{i * 10 + 0.01:.2f}%,{(i + 1) * 10}%{{opacity:1}}"
              f"{(i + 1) * 10 + 0.01:.2f}%,100%{{opacity:0}}}}" for i in range(10))
    + ".su>g{opacity:0;animation:2s linear infinite}"
    + "".join(f".su>g:nth-child({i + 1}){{animation-name:u{i + 1}}}" for i in range(8))
    + "".join(f"@keyframes u{i + 1}{{0%,{i * 12.5}%{{opacity:0}}{i * 12.5 + 0.01:.2f}%,{(i + 1) * 12.5}%{{opacity:1}}"
              f"{(i + 1) * 12.5 + 0.01:.2f}%,100%{{opacity:0}}}}" for i in range(8))
)


def spark(x, y, kind):
    """12x12 agent mark with its top-left at x, y."""
    if kind == "claude":
        inner = "".join(f"<g>{f}</g>" for f in CLAUDE_FRAMES)
        return f'<g transform="translate({x} {y})" fill="{CLAUDE}" class="sc">{inner}</g>'
    if kind == "cursor":
        inner = "".join(f"<g>{f}</g>" for f in CURSOR_FRAMES)
        return f'<g transform="translate({x} {y})" fill="{MONOFG}" class="su">{inner}</g>'
    return f'<circle cx="{x + 6}" cy="{y + 6}" r="1.55" fill="{DIM}"/>'


def agent_row(sc, y, name, sess, kind, working):
    """Agent sub-row. working: windows when the agent is busy."""
    base = text(70, y, f'{name} <tspan fill="{DIM}">({sess})</tspan>', size=12.2)
    w = sc.vis(working, fade=0.2) if working else None
    idle_windows = invert(working, sc.L)
    i = sc.vis(idle_windows, fade=0.2) if working else None
    color = CLAUDE if kind == "claude" else MONOFG
    busy = g(spark(50, y - 10, kind) + text(316, y, "working", size=11.8, fill=color, weight=600, anchor="end"), w)
    rest = g(spark(50, y - 10, "rest") + text(316, y, "idle", size=11.8, fill=DIM, anchor="end"), i)
    return base + (busy if working else "") + rest


def invert(windows, L):
    """Complement of a list of windows on [0, L]."""
    out, t = [], 0
    for a, b in sorted(windows):
        if a > t:
            out.append((t, a))
        t = max(t, b)
    if t < L:
        out.append((t, L))
    return out


# ---------------------------------------------------------------- card chrome

def defs():
    return f"""<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#231a13"/><stop offset="1" stop-color="#110d0a"/></linearGradient>
<radialGradient id="glow" cx="18%" cy="4%" r="60%"><stop offset="0" stop-color="#a64b23" stop-opacity=".32"/><stop offset="1" stop-color="#a64b23" stop-opacity="0"/></radialGradient>
<filter id="pop" x="-20%" y="-10%" width="140%" height="130%"><feDropShadow dx="0" dy="16" stdDeviation="16" flood-color="#000" flood-opacity=".55"/></filter>
<filter id="knob" x="-50%" y="-50%" width="200%" height="200%"><feDropShadow dx="0" dy="1" stdDeviation=".8" flood-color="#000" flood-opacity=".4"/></filter>
<filter id="cur" x="-50%" y="-50%" width="200%" height="200%"><feDropShadow dx="0" dy="1" stdDeviation="1" flood-color="#000" flood-opacity=".6"/></filter>
<clipPath id="card"><rect width="{W}" height="{H}" rx="18"/></clipPath>
</defs>"""


def chrome_top(kicker, headline, clock):
    """Card background, kicker, headline, menu-bar pill. `clock` is extra markup."""
    pill_x, pill_w = 92, 176
    return (
        f'<rect width="{W}" height="{H}" fill="url(#bg)"/>'
        f'<rect width="{W}" height="{H}" fill="url(#glow)"/>'
        + text(W / 2, 34, kicker, size=10, fill=KICKER, weight=700, anchor="middle",
               extra=f' font-family="{MONO}" letter-spacing="2.6"')
        + text(W / 2, 60, headline, size=19, fill=HEADLINE, weight=800, anchor="middle", extra=' letter-spacing="-.3"')
        + f'<rect x="{pill_x}" y="76" width="{pill_w}" height="28" rx="11" fill="rgba(255,255,255,.055)" stroke="rgba(255,255,255,.1)"/>'
        # wifi
        + f'<g transform="translate(103 81) scale(.75)" fill="none" stroke="#bdb6ac" stroke-width="2" stroke-linecap="round">'
          f'<path d="M5 12.55a11 11 0 0 1 14.08 0M8.53 16.11a6 6 0 0 1 6.95 0M12 20h.01"/></g>'
        # battery
        + f'<g transform="translate(130 83.5) scale(.8)" fill="none" stroke="#bdb6ac" stroke-width="1.5">'
          f'<rect x="1" y="3" width="22" height="10" rx="3"/><path d="M26 6.5v3" stroke-linecap="round"/>'
          f'<rect x="3" y="5" width="14" height="6" rx="1.5" fill="#bdb6ac" stroke="none"/></g>'
        + clock
    )


def menubar_cup(on_cls, off_cls, steam_cls):
    return cup(163, 78, 24, on_cls, off_cls, steam_cls, menubar=True)


def clock_text(s, cls=None):
    return text(198, 95, s, size=13, fill="#ece6dd", weight=500, cls=cls,
                extra=' style="font-variant-numeric:tabular-nums"')


def popover():
    """Panel body + notch under the menu-bar cup (cup centre x = 175)."""
    nx = 175
    return (f'<g filter="url(#pop)"><rect x="30" y="{P}" width="300" height="334" rx="16" fill="{BG}" stroke="{BORDER}"/></g>'
            f'<path d="M{nx - 7} {P + 0.6}L{nx} {P - 6}L{nx + 7} {P + 0.6}Z" fill="{BG}"/>'
            f'<path d="M{nx - 7} {P + 0.5}L{nx} {P - 6}L{nx + 7} {P + 0.5}" fill="none" stroke="{BORDER}"/>')


def header(cup_markup, titles):
    """titles: markup for the title/sub swaps."""
    return (f'<rect x="40" y="{P + 10}" width="280" height="46" rx="10" fill="{HEAD}"/>'
            + cup_markup + titles
            + f'<g transform="translate(47 {P + 67}) scale(.875)" fill="none" stroke="{DIM}" stroke-width="1.4" stroke-linecap="round">'
              f'<circle cx="8" cy="8" r="6.6"/><path d="M5.2 8.6c1-1.6 2-1.6 2.9 0 .9 1.6 1.9 1.6 2.9 0"/></g>'
            + text(66, P + 79, "WindowServer: declaring the user active", size=11.7, fill=SUB)
            + f'<path d="M40 {P + 91.5}H320" stroke="{HAIR}"/>')


def footer():
    return (f'<path d="M40 {P + 304.5}H320" stroke="{HAIR}"/>'
            f'<g transform="translate(144 {P + 315})" fill="none" stroke="{DIM}" stroke-width="2" stroke-linecap="round">'
            f'<path d="m2.5 4.5 3.5 3 3.5-3"/></g>'
            + text(160, P + 323.5, "Show more", size=11.7, fill=SUB))


def title_pair(title, sub, cls=None):
    return g(text(90, P + 30, title, size=14.7, fill=STRONG, weight=700)
             + text(90, P + 47, sub, size=12.2, fill=SUB, extra=' style="font-variant-numeric:tabular-nums"'), cls)


def cursor_markup(move_cls, tap_cls, vis_cls):
    path = ('M5.5 3.2v17.6c0 .45.55.67.86.35l4.86-4.86a.5.5 0 0 1 .35-.15h6.87c.45 0 .67-.54.35-.85'
            'L6.36 2.85a.5.5 0 0 0-.86.35Z')
    return (f'<g class="{vis_cls}"><g class="{move_cls}"><g class="{tap_cls}">'
            f'<path d="{path}" transform="scale(.95) translate(-5.5 -3)" fill="#fff" stroke="#1c1c1e" '
            f'stroke-width="1.3" filter="url(#cur)"/></g></g></g>')


def wrap(sc, body, label):
    css = ("text{font-family:" + FONT + "}"
           ".steam{opacity:0;animation:steam 3s ease-in-out infinite}"
           ".steam.s2{animation-delay:1s}.steam.s3{animation-delay:2s}"
           "@keyframes steam{0%{opacity:0;transform:translateY(4px)}30%{opacity:.9;transform:translateY(0)}"
           "65%{opacity:.35;transform:translateY(-3px)}100%{opacity:0;transform:translateY(-6px)}}"
           + SPARK_CSS + "".join(sc.css)
           + "@media (prefers-reduced-motion:reduce){*{animation-play-state:paused!important;animation-delay:0s!important}"
             ".sc>g:first-child,.su>g:first-child{animation:none!important;opacity:1}}")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'role="img" aria-label="{esc(label)}">\n<style>{css}</style>\n{defs()}\n'
            f'<g clip-path="url(#card)">{body}</g>\n'
            f'<rect x=".5" y=".5" width="{W - 1}" height="{H - 1}" rx="17.5" fill="none" stroke="rgba(255,255,255,.07)"/>\n</svg>\n')


# ---------------------------------------------------------------- scenes

def scene_manual():
    """Toggle on, count up, pick 1 h, count down, toggle off."""
    sc = Scene(12)
    ON, CLICK_ON, CHIP, CLICK_OFF = 1.6, 1.5, 4.0, 10.3
    OFF = 10.4
    on_w = [(ON, OFF)]
    off_w = invert(on_w, sc.L)

    on, off, steam = sc.vis(on_w), sc.vis(off_w), sc.vis(on_w, 0.4)
    mb_on, mb_off, mb_steam = sc.vis(on_w), sc.vis(off_w), sc.vis(on_w, 0.4)

    titles = title_pair("Idle", "System can sleep", sc.vis(off_w, 0.15))
    ticks = [("Awake for 0:00", ON, 2.6), ("Awake for 0:01", 2.6, 3.6), ("Awake for 0:02", 3.6, CHIP)]
    for i, s in enumerate(range(10)):
        t0 = CHIP + i
        if t0 >= OFF:
            break
        ticks.append((f"Stops in 59:{59 - i:02d}", t0, min(t0 + 1, OFF)))
    titles += g(text(90, P + 30, "Brewing", size=14.7, fill=STRONG, weight=700), sc.vis(on_w, 0.15))
    for s, a, b in ticks:
        titles += text(90, P + 47, s, size=12.2, fill=SUB, cls=sc.vis([(a, b)], 0.02),
                       extra=' style="font-variant-numeric:tabular-nums"')

    rows = ""
    y = P + 96
    # Mode switch: triggers set up, Manual chosen
    rows += segmented(y + 4, manual=True)
    y += 34
    # Keep awake
    rows += text(42, y + 22, "Keep awake") + switch(sc, y + 18, on_w)
    # For [menu]: a Stop in shortcut ends the session early, the mode label stays
    rows += text(42, y + 54, "For")
    rows += f'<rect x="216" y="{y + 39}" width="104" height="22" rx="7" fill="{CTL}"/>'
    rows += text(298, y + 54.5, "Indefinitely", size=12.2, anchor="end")
    rows += (f'<g transform="translate(303 {y + 46})" fill="none" stroke="{DIM}" stroke-width="2" '
             f'stroke-linecap="round"><path d="m1.5 3 3 2.6 3-2.6"/></g>')
    # Stop in chips (only while brewing)
    chips = text(42, y + 86, "Stop in")
    cx = 186
    chip_xy = {}
    for label, w in (("15 min", 46), ("30 min", 48), ("1 h", 30)):
        chips += f'<rect x="{cx}" y="{y + 72}" width="{w}" height="21" rx="7" fill="{CTL}"/>'
        chips += text(cx + w / 2, y + 86.5, label, size=11.7, fill=AMBER, weight=600, anchor="middle")
        chip_xy[label] = (cx, w)
        cx += w + 6
    hx, hw = chip_xy["1 h"]
    chips += g(f'<rect x="{hx}" y="{y + 72}" width="{hw}" height="21" rx="7" fill="{BTN}"/>'
               + text(hx + hw / 2, y + 86.5, "1 h", size=11.7, fill=BTNTX, weight=700, anchor="middle"),
               sc.vis([(CHIP, CHIP + 0.45)], 0.1))
    rows += g(chips, sc.vis([(ON + 0.3, OFF - 0.1)], 0.3))
    # Lower menu slides up while Stop in is collapsed (the real menu's height fade)
    lower = f'<path d="M40 {y + 104.5}H320" stroke="{HAIR}"/>'
    lower += text(42, y + 128, "Keep awake with lid closed") + info(213, y + 124) + switch(sc, y + 124, [])
    lower += text(42, y + 160, "Pause on low battery") + info(178, y + 156) + switch(sc, y + 156, [])
    shift = sc.track([(0, -32), (ON, -32, "ease-in-out"), (ON + 0.35, 0), (OFF, 0, "ease-in-out"), (OFF + 0.35, -32)],
                     lambda v: f"transform:translateY({v}px)")
    rows += g(lower, shift)

    # Cursor: appear, click toggle, glide to 1 h, rest, back to toggle, click off.
    tog = (306, y + 21)
    chip = (hx + hw * 0.6, y + 86)
    rest = (250, P + 270)
    move = sc.move([(0, *rest), (0.6, *rest), (1.4, *tog), (2.8, *tog), (3.6, *chip),
                    (4.7, *chip), (5.6, *rest), (9.2, *rest), (10.0, *tog)])
    vis = sc.vis([(0.25, 5.8), (9.0, 11.0)], 0.35)
    tap = sc.tap([CLICK_ON, CHIP - 0.05, CLICK_OFF])

    body = (chrome_top("TIMED SESSIONS", "On, off, or for a set time.", clock_text("Thu 09:41"))
            + menubar_cup(mb_on, mb_off, mb_steam)
            + popover()
            + header(cup(48, P + 18, 30, on, off, steam), titles)
            + rows + footer()
            + cursor_markup(move, tap, vis))
    return wrap(sc, body, "Keepresso menu: switching keep-awake on, picking a one hour session that counts down, then switching it off")


def scene_triggers():
    """Agents and conditions hold the Mac awake, then release it."""
    sc = Scene(12)
    CUR_ON, NET_ON, NET_OFF, CUR_OFF = 3.0, 3.6, 7.0, 7.6
    CLAUDE_OFF, IDLE, BACK = 8.6, 9.4, 11.2
    brew_w = [(0, IDLE), (BACK, sc.L)]
    idle_w = [(IDLE, BACK)]

    on, off, steam = sc.vis(brew_w), sc.vis(idle_w), sc.vis(brew_w, 0.4)
    mb_on, mb_off, mb_steam = sc.vis(brew_w), sc.vis(idle_w), sc.vis(brew_w, 0.4)

    titles = g(text(90, P + 30, "Brewing", size=14.7, fill=STRONG, weight=700), sc.vis(brew_w, 0.15))
    titles += g(text(90, P + 30, "Idle", size=14.7, fill=STRONG, weight=700), sc.vis(idle_w, 0.15))
    subs = [("Held by 1 condition", [(0, NET_ON), (NET_OFF, IDLE), (BACK, sc.L)]),
            ("Held by 2 conditions", [(NET_ON, NET_OFF)]),
            ("System can sleep", idle_w)]
    for s, w in subs:
        titles += text(90, P + 47, s, size=12.2, fill=SUB, cls=sc.vis(w, 0.12))

    y = P + 96
    rows = ""
    # AI agent working
    rows += check(50, y + 14, sc.vis(brew_w, 0.2)) + ring(50, y + 14, sc.vis(idle_w, 0.2))
    rows += text(66, y + 18.5, "AI agent working (+300s)")
    rows += agent_row(sc, y + 40, "claude", "Claude app", "claude", [(0, CLAUDE_OFF), (BACK, sc.L)])
    rows += agent_row(sc, y + 61, "codex", "s001", "rest", [])
    rows += agent_row(sc, y + 82, "cursor-agent", "s002", "cursor", [(CUR_ON, CUR_OFF)])
    # Conditions
    rows += ring(50, y + 104) + text(66, y + 108.5, "Playing a game")
    rows += check(50, y + 130, sc.vis([(NET_ON, NET_OFF)], 0.2)) + ring(50, y + 130, sc.vis(invert([(NET_ON, NET_OFF)], sc.L), 0.2))
    rows += text(66, y + 134.5, "Network above 1 MB/s")
    rows += ring(50, y + 156) + text(66, y + 160.5, "Downloading in “Downloads”")
    # Mode switch on Automatic, below the conditions it hands control to
    rows += f'<path d="M40 {y + 168.5}H320" stroke="{HAIR}"/>'
    rows += segmented(y + 175, manual=False)

    body = (chrome_top("SMART TRIGGERS", "Awake only while it matters.", clock_text("Thu 09:41"))
            + menubar_cup(mb_on, mb_off, mb_steam)
            + popover()
            + header(cup(48, P + 18, 30, on, off, steam), titles)
            + rows + footer())
    return wrap(sc, body, "Keepresso menu: AI agents and a network condition hold the Mac awake, then it goes idle when the work stops")


def scene_lid():
    """Flip closed-lid mode on, the display goes dark, the work keeps going."""
    sc = Scene(12)
    LID_ON, DARK, LIGHT, LID_OFF = 1.9, 4.6, 8.8, 10.9
    lid_w = [(LID_ON, LID_OFF)]

    steam, mb_steam = sc.vis([(0, sc.L)]), sc.vis([(0, sc.L)])
    titles = title_pair("Brewing", "Held by 1 condition")

    y = P + 96
    rows = check(50, y + 14) + text(66, y + 18.5, "AI agent working (+300s)")
    rows += agent_row(sc, y + 40, "claude", "Claude app", "claude", [(0, sc.L)])
    rows += f'<path d="M40 {y + 52.5}H320" stroke="{HAIR}"/>'
    rows += segmented(y + 60, manual=False)
    y += 36
    rows += f'<path d="M40 {y + 58.5}H320" stroke="{HAIR}"/>'
    rows += text(42, y + 80, "Keep awake with lid closed") + info(213, y + 76) + switch(sc, y + 76, lid_w)
    # The caption only shows while the mode is on, the row below makes room.
    rows += g(text(42, y + 102, "Stays awake on battery too. The display turns", size=11.7, fill=SUB)
              + text(42, y + 117, "off when the lid closes. Turn it off before", size=11.7, fill=SUB)
              + text(42, y + 132, "putting it in a bag.", size=11.7, fill=SUB),
              sc.vis([(LID_ON + 0.2, LID_OFF - 0.1)], 0.3))
    # "Only while brewing" stays off: when on, it drives the lid switch itself.
    below = text(42, y + 160, "Only while brewing") + info(164, y + 156) + switch(sc, y + 156, [])
    shift = sc.track([(0, -48), (LID_ON, -48, "ease-in-out"), (LID_ON + 0.35, 0),
                      (LID_OFF, 0, "ease-in-out"), (LID_OFF + 0.35, -48)],
                     lambda v: f"transform:translateY({v}px)")
    rows += g(below, shift)

    # Display off: the whole card dims, the work keeps going in the dark.
    dark_w = [(DARK, LIGHT)]
    dark = (f'<rect width="{W}" height="{H}" fill="#050403" class="{sc.vis(dark_w, 0.6)}"/>'
            + g(cup(156, 168, 48, None, None, None)
                + text(W / 2, 254, "Lid closed", size=17, fill=HEADLINE, weight=700, anchor="middle")
                + text(W / 2, 276, "Display off. Mac still awake.", size=12.5, fill=SUB, anchor="middle")
                + f'<rect x="104" y="296" width="152" height="28" rx="14" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.08)"/>'
                + spark(118, 304, "claude")
                + text(137, 314.5, "claude", size=12.2, fill=TEXT)
                + text(242, 314.5, "working", size=11.8, fill=CLAUDE, weight=600, anchor="end"),
                sc.vis([(DARK + 0.5, LIGHT - 0.3)], 0.5)))

    # Clock jumps forward while the lid was shut, settles back for the loop.
    clock = (clock_text("Thu 09:41", sc.vis([(0, LIGHT - 0.4), (11.7, sc.L)], 0.3))
             + clock_text("Thu 11:56", sc.vis([(LIGHT - 0.4, 11.7)], 0.3)))

    tog = (306, y + 79)
    rest = (262, P + 300)
    move = sc.move([(0, *rest), (0.6, *rest), (1.5, *tog), (2.3, *tog), (3.2, *rest),
                    (9.6, *rest), (10.5, *tog)])
    vis = sc.vis([(0.3, 3.4), (9.4, 11.4)], 0.35)
    tap = sc.tap([LID_ON - 0.1, LID_OFF - 0.1])

    body = (chrome_top("CLOSED-LID MODE", "Close the lid. Keep brewing.", clock)
            + menubar_cup("", None, mb_steam)
            + popover()
            + header(cup(48, P + 18, 30, "", None, steam), titles)
            + rows + footer()
            + cursor_markup(move, tap, vis)
            + dark)
    return wrap(sc, body, "Keepresso menu: turning on keep awake with lid closed, the display goes dark while an AI agent keeps working")


def main():
    for name, fn in (("demo_manual", scene_manual), ("demo_triggers", scene_triggers), ("demo_lid", scene_lid)):
        path = OUT / f"{name}.svg"
        path.write_text(fn())
        print(f"wrote {path.relative_to(OUT.parents[1])} ({path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
