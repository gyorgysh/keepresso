#!/usr/bin/env python3
"""Generate the 1:1 redesigned Pervigil tilted close-up hero SVG for README.md.

Produces:
  - docs/assets/hero_menu.svg   1:1 (600x600) tilted close-up over the Pervigil brand blue gradient

Pure self-contained vector SVG (no script, no external fonts, no bitmaps) with
subtle CSS micro-motion respecting prefers-reduced-motion, compatible with
GitHub <img> rendering.

    python3 tools/readme-demo/gen_redesign_svgs.py
"""

from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "docs" / "assets"

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"

# Frosted dark glass panel tokens
PANEL_BG = "#1A1E26"
PANEL_EDGE = "#0F141E"
TEXT = "#F6F7F9"
TEXT2 = "#B4BAC5"
TEXT3 = "#868D9B"
FILL = "rgba(255,255,255,0.09)"
FILL2 = "rgba(255,255,255,0.16)"
SEP = "rgba(255,255,255,0.12)"

# Pervigil brand blue gradient tokens (docs/assets/brand/README.md)
BRAND_TOP = "#6EAFF6"
BRAND_MID = "#3492FA"
BRAND_BOT = "#007AFF"

ACCENT_TOP = "#56A5FF"
ACCENT_BOT = "#006AE5"
ACCENT_TEXT = "#82BBF9"
GREEN_TEXT = "#4ADE80"
GREEN_SOFT = "rgba(48,209,88,0.22)"
CLAUDE_CORAL = "#FF9673"
CLAUDE_BG = "#D97757"
ANTIGRAVITY_BLUE = "#7AB8FF"

# Exact Pervigil mark geometry (viewBox 0 0 562 650)
MARK_FULL = "M0 0H562V650H0V231H190L0 124ZM190 231 557 438 190 645Z"
MARK_INNER = "251 334 435 438 251 542"

# Authentic agent brand paths from Sources/Pervigil/AgentBrands.xcassets (viewBox 0 0 24 24)
CURSOR_PATH = (
    "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724"
    "l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726"
    "L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515"
    "L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
)
ANTIGRAVITY_PATH = (
    "M21.751 22.607c1.34 1.005 3.35.335 1.508-1.508C17.73 15.74 18.904 1 12.037 1"
    " 5.17 1 6.342 15.74.815 21.1c-2.01 2.009.167 2.511 1.507 1.506"
    " 5.192-3.517 4.857-9.714 9.715-9.714 4.857 0 4.522 6.197 9.714 9.715z"
)
CODEX_PATH = (
    "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9"
    "A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966"
    " 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24"
    "a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729z"
    "m-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813"
    "v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944z"
    "m-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0"
    "l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464z"
    "M2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543"
    "-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872z"
    "m16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913"
    "a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667z"
    "m2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974"
    "a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66z"
    "M8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537"
    "l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813z"
    "m1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
)
GEMINI_PATH = (
    "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55"
    "Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81"
    "Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58"
    "Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
)


def claude_tile(x: float, y: float, size: float = 18, rx: float = 5) -> str:
    s = size / 16.0
    return f"""<g transform="translate({x},{y}) scale({s:.4f})">
      <rect width="16" height="16" rx="{rx / s:.2f}" fill="{CLAUDE_BG}"/>
      <g transform="translate(8,8)" fill="#FFFFFF">
        <circle r="1.45"/>
        <rect x="-0.65" y="-5.2" width="1.3" height="3.2" rx="0.65"/>
        <rect x="-0.65" y="2.0" width="1.3" height="3.2" rx="0.65"/>
        <rect x="-5.2" y="-0.65" width="3.2" height="1.3" rx="0.65"/>
        <rect x="2.0" y="-0.65" width="3.2" height="1.3" rx="0.65"/>
        <rect x="-0.65" y="-4.8" width="1.3" height="2.8" rx="0.65" transform="rotate(45)"/>
        <rect x="-0.65" y="2.0" width="1.3" height="2.8" rx="0.65" transform="rotate(45)"/>
        <rect x="-0.65" y="-4.8" width="1.3" height="2.8" rx="0.65" transform="rotate(-45)"/>
        <rect x="-0.65" y="2.0" width="1.3" height="2.8" rx="0.65" transform="rotate(-45)"/>
      </g>
    </g>"""


def brand_badge(
    x: float,
    y: float,
    path: str,
    bg: str,
    fg: str,
    size: float = 18,
    rx: float = 5,
    pad: float = 3.2,
    stroke: str = "",
) -> str:
    inner = size - pad * 2
    sc = inner / 24.0
    st = f' stroke="{stroke}" stroke-width="1.2"' if stroke else ""
    return f"""<g transform="translate({x},{y})">
      <rect width="{size}" height="{size}" rx="{rx}" fill="{bg}"{st}/>
      <g transform="translate({pad:.2f},{pad:.2f}) scale({sc:.4f})" fill="{fg}">
        <path fill-rule="evenodd" d="{path}"/>
      </g>
    </g>"""


def cat_tile(x: float, y: float, kind: str, active: bool = False) -> str:
    bg, fg = (GREEN_SOFT, GREEN_TEXT) if active else (FILL, TEXT3)
    icons = {
        "sparkle": f'<path d="M8 1.6l1.6 4.8 4.8 1.6-4.8 1.6L8 14.4 6.4 9.6 1.6 8l4.8-1.6z" fill="{fg}"/>',
        "mic": f'<g fill="none" stroke="{fg}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="1.8" width="4" height="7.4" rx="2"/><path d="M3.8 7.8a4.2 4.2 0 0 0 8.4 0M8 12v2.2"/></g>',
        "download": f'<g fill="none" stroke="{fg}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v8M4.8 7.2 8 10.4l3.2-3.2M3 13.5h10"/></g>',
    }
    return f"""<g transform="translate({x},{y})">
      <rect width="20" height="20" rx="6.5" fill="{bg}"/>
      <g transform="translate(3.5,3.5) scale(0.8125)">{icons[kind]}</g>
    </g>"""


def build_tilted_square_hero() -> str:
    """1:1 (600x600) tilted frosted-glass close-up over the Pervigil brand blue gradient."""
    size = 600
    pw, ph = 356, 480
    panel_xform = "translate(68, 178) rotate(-6.8) skewX(7.5) scale(1.66)"

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}" role="img" aria-label="1:1 close-up tilted view of the Pervigil menu active with Claude, Cursor, Antigravity, and Codex over the Pervigil blue gradient">
<style>
  text {{ font-family: {FONT}; }}
  .num {{ font-variant-numeric: tabular-nums; letter-spacing: -0.35px; }}
  .breathe {{ animation: breathe 3.4s ease-in-out infinite; }}
  .pulse1 {{ animation: workPulse 2.6s ease-in-out infinite; }}
  .pulse2 {{ animation: workPulse 2.6s ease-in-out 0.6s infinite; }}
  .pulse3 {{ animation: workPulse 2.6s ease-in-out 1.2s infinite; }}
  @keyframes breathe {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: 0.44; }} }}
  @keyframes workPulse {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: 0.62; }} }}
  @media (prefers-reduced-motion: reduce) {{
    .breathe, .pulse1, .pulse2, .pulse3 {{ animation: none !important; }}
  }}
</style>
<defs>
  <!-- Pervigil logo blue gradient backdrop -->
  <linearGradient id="brandBg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="{BRAND_TOP}"/>
    <stop offset="52%" stop-color="{BRAND_MID}"/>
    <stop offset="100%" stop-color="{BRAND_BOT}"/>
  </linearGradient>
  <radialGradient id="topBloom" cx="18%" cy="10%" r="68%">
    <stop offset="0%" stop-color="#B8DCFF" stop-opacity="0.42"/>
    <stop offset="60%" stop-color="#6EAFF6" stop-opacity="0.08"/>
    <stop offset="100%" stop-color="#6EAFF6" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="deepCorner" cx="92%" cy="94%" r="65%">
    <stop offset="0%" stop-color="#004BB5" stop-opacity="0.38"/>
    <stop offset="100%" stop-color="#004BB5" stop-opacity="0"/>
  </radialGradient>

  <linearGradient id="markGrad" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="{ACCENT_TOP}"/>
    <stop offset="100%" stop-color="{ACCENT_BOT}"/>
  </linearGradient>
  <linearGradient id="glassTint" x1="0" y1="0" x2="0.45" y2="1">
    <stop offset="0%" stop-color="#1E2533" stop-opacity="0.86"/>
    <stop offset="48%" stop-color="{PANEL_BG}" stop-opacity="0.90"/>
    <stop offset="100%" stop-color="#12161F" stop-opacity="0.94"/>
  </linearGradient>
  <linearGradient id="glassSheen" x1="0" y1="0" x2="0.72" y2="0.62">
    <stop offset="0%" stop-color="#CFE7FF" stop-opacity="0.16"/>
    <stop offset="35%" stop-color="#FFFFFF" stop-opacity="0.03"/>
    <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="rimLight" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.56"/>
    <stop offset="38%" stop-color="#B8DCFF" stop-opacity="0.28"/>
    <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0.08"/>
  </linearGradient>
  <linearGradient id="agGrad" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#6EAFF6"/>
    <stop offset="100%" stop-color="#A67CFF"/>
  </linearGradient>
  <linearGradient id="gmGrad" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#4C8DF6"/>
    <stop offset="100%" stop-color="#B074F7"/>
  </linearGradient>
  <filter id="panelShadow" x="-18%" y="-15%" width="140%" height="140%">
    <feDropShadow dx="-8" dy="24" stdDeviation="22" flood-color="#00235C" flood-opacity="0.48"/>
  </filter>
  <filter id="markGlow" x="-28%" y="-28%" width="156%" height="156%">
    <feDropShadow dx="0" dy="4" stdDeviation="6.5" flood-color="#006AE5" flood-opacity="0.54"/>
  </filter>
  <clipPath id="viewport"><rect width="{size}" height="{size}" rx="24"/></clipPath>

  <!-- Notched avatar-stack masks -->
  <mask id="n1">
    <rect x="0" y="0" width="120" height="26" fill="#fff"/>
    <circle cx="9.5" cy="9.5" r="11.2" fill="#000"/>
  </mask>
  <mask id="n2">
    <rect x="0" y="0" width="120" height="26" fill="#fff"/>
    <circle cx="25.5" cy="9.5" r="11.2" fill="#000"/>
  </mask>
  <mask id="n3">
    <rect x="0" y="0" width="120" height="26" fill="#fff"/>
    <circle cx="41.5" cy="9.5" r="11.2" fill="#000"/>
  </mask>
</defs>

<g clip-path="url(#viewport)">
  <!-- Pervigil logo blue gradient background -->
  <rect width="{size}" height="{size}" fill="url(#brandBg)"/>
  <rect width="{size}" height="{size}" fill="url(#topBloom)"/>
  <rect width="{size}" height="{size}" fill="url(#deepCorner)"/>

  <!-- Tilted perspective close-up of the top-left of the active panel -->
  <g transform="{panel_xform}">
    <!-- Cast shadow & 3D thickness slab -->
    <rect x="-5" y="7" width="{pw}" height="{ph}" rx="16" fill="{PANEL_EDGE}" opacity="0.78" filter="url(#panelShadow)"/>
    <rect x="-2.5" y="3.5" width="{pw}" height="{ph}" rx="15.5" fill="#131824" opacity="0.86" stroke="rgba(255,255,255,0.16)" stroke-width="0.6"/>

    <!-- Translucent dark glass surface + specular sheen + crisp rim -->
    <rect width="{pw}" height="{ph}" rx="15" fill="url(#glassTint)"/>
    <rect width="{pw}" height="{ph}" rx="15" fill="url(#glassSheen)" stroke="url(#rimLight)" stroke-width="1"/>

    <!-- ===== TOP-LEFT HERO STATUS HEADER ===== -->
    <g transform="translate(14, 14)">
      <rect width="54" height="54" rx="13.5" fill="url(#markGrad)" filter="url(#markGlow)"/>
      <rect x="0.6" y="0.6" width="52.8" height="52.8" rx="13" fill="none" stroke="rgba(255,255,255,0.34)" stroke-width="0.8"/>
      <g transform="translate(14.3, 12.2) scale(0.045)" fill="#FFFFFF">
        <path fill-rule="evenodd" d="{MARK_FULL}"/>
        <polygon class="breathe" points="{MARK_INNER}"/>
      </g>
      <!-- Closed-lid armed badge -->
      <g transform="translate(38, 38)">
        <circle cx="9" cy="9" r="9.5" fill="#171A21" stroke="rgba(255,255,255,0.24)" stroke-width="0.85"/>
        <g transform="translate(3.2, 3.4) scale(0.72)" fill="none" stroke="{ACCENT_TEXT}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
          <rect x="3" y="3.5" width="10" height="7" rx="1.3"/>
          <path d="M1.5 12.5h13"/>
        </g>
      </g>
    </g>

    <!-- Awake title + notched overlapping agent icon stack -->
    <text x="80" y="34" fill="{TEXT}" font-size="15.5" font-weight="600" letter-spacing="-0.2">Awake</text>
    <g transform="translate(80, 42)">
      {claude_tile(0, 0, size=19, rx=5)}
      <g mask="url(#n1)">
        {brand_badge(16, 0, CURSOR_PATH, "#2B2F3B", "#FFFFFF", size=19, rx=5, pad=3.4)}
      </g>
      <g mask="url(#n2)">
        {brand_badge(32, 0, ANTIGRAVITY_PATH, "#1D2C47", "url(#agGrad)", size=19, rx=5, pad=3.3)}
      </g>
      <g mask="url(#n3)">
        {brand_badge(48, 0, CODEX_PATH, "#2D313B", "#ECEEF2", size=19, rx=5, pad=3.4)}
      </g>
      <text x="72" y="13.5" fill="{TEXT2}" font-size="11.5" font-weight="600">+2</text>
    </g>

    <!-- Held clock + stop button (pushed past the right edge as the panel overflows) -->
    <text x="304" y="48" class="num" fill="{TEXT2}" font-size="19.5" font-weight="500" text-anchor="end">28:14</text>
    <g transform="translate(316, 28)">
      <circle cx="13" cy="13" r="13" fill="{FILL2}"/>
      <path d="M9.3 9.3l7.4 7.4M16.7 9.3l-7.4 7.4" stroke="{TEXT2}" stroke-width="1.8" stroke-linecap="round"/>
    </g>

    <!-- Segmented Mode Switch (Automatic active) -->
    <g transform="translate(14, 80)">
      <rect width="328" height="27" rx="8" fill="{FILL}"/>
      <rect x="2" y="2" width="162" height="23" rx="6" fill="rgba(255,255,255,0.24)"/>
      <text x="83" y="17.5" fill="{TEXT}" font-size="12" font-weight="500" text-anchor="middle">Automatic</text>
      <text x="245" y="17.5" fill="{TEXT2}" font-size="12" font-weight="500" text-anchor="middle">Manual</text>
    </g>

    <!-- ===== ACTIVE TRIGGERS & AI AGENTS SECTION ===== -->
    <g transform="translate(14, 120)">
      <text x="2" y="9" fill="{TEXT3}" font-size="10.8" font-weight="600">Awake while any is met</text>
      <text x="326" y="9" fill="{TEXT3}" font-size="10.8" text-anchor="end">2 of 4</text>

      <!-- Trigger header: AI agent working -->
      {cat_tile(0, 17, "sparkle", active=True)}
      <text x="28" y="31.2" fill="{TEXT}" font-size="12.4" font-weight="600">AI agent working <tspan fill="{TEXT3}" font-size="11" font-weight="400">(3 min grace)</tspan></text>

      <!-- Agent 1: Claude -->
      {claude_tile(28, 42, size=18, rx=4.8)}
      <text x="53" y="55" fill="{TEXT}" font-size="12" font-weight="500">claude <tspan fill="{TEXT3}" font-weight="400">(pervigil)</tspan></text>
      <text x="326" y="55" class="pulse1" fill="{CLAUDE_CORAL}" font-size="11" font-weight="600" text-anchor="end">working</text>

      <!-- Agent 2: Cursor -->
      {brand_badge(28, 65, CURSOR_PATH, "#2B2F3B", "#FFFFFF", size=18, rx=4.8, pad=3.2)}
      <text x="53" y="78" fill="{TEXT}" font-size="12" font-weight="500">cursor <tspan fill="{TEXT3}" font-weight="400">(web-app)</tspan></text>
      <text x="326" y="78" class="pulse2" fill="{TEXT}" font-size="11" font-weight="600" text-anchor="end">working</text>

      <!-- Agent 3: Antigravity -->
      {brand_badge(28, 88, ANTIGRAVITY_PATH, "#1D2C47", "url(#agGrad)", size=18, rx=4.8, pad=3.0)}
      <text x="53" y="101" fill="{TEXT}" font-size="12" font-weight="500">antigravity <tspan fill="{TEXT3}" font-weight="400">(pervigil)</tspan></text>
      <text x="326" y="101" class="pulse3" fill="{ANTIGRAVITY_BLUE}" font-size="11" font-weight="600" text-anchor="end">working</text>

      <!-- Agent 4+: Codex + Gemini stacked "+2" -->
      <g transform="translate(28, 111)">
        {brand_badge(0, 0, CODEX_PATH, "#2D313B", "#ECEEF2", size=18, rx=4.8, pad=3.2, stroke=PANEL_BG)}
        {brand_badge(12, 0, GEMINI_PATH, "#252B42", "url(#gmGrad)", size=18, rx=4.8, pad=3.0, stroke=PANEL_BG)}
      </g>
      <text x="66" y="124" fill="{TEXT2}" font-size="12">codex <tspan fill="{TEXT3}" font-weight="600">+2</tspan></text>
      <text x="326" y="124" fill="{TEXT2}" font-size="11" font-weight="600" text-anchor="end">2 working</text>

      <!-- Below (partially visible / overflowing off bottom edge) -->
      {cat_tile(0, 140, "mic", active=True)}
      <text x="28" y="154.2" fill="{TEXT}" font-size="12.2" font-weight="500">Microphone in use</text>

      {cat_tile(0, 166, "download", active=False)}
      <text x="28" y="180.2" fill="{TEXT2}" font-size="12.2">Download in progress</text>

      <line x1="0" y1="196" x2="328" y2="196" stroke="{SEP}" stroke-width="1"/>
    </g>
  </g>
</g>
<!-- Crisp outer viewport hairline -->
<rect width="{size}" height="{size}" rx="24" fill="none" stroke="rgba(255,255,255,0.28)" stroke-width="1"/>
</svg>
"""
    return svg


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    hero_path = OUT / "hero_menu.svg"
    hero_path.write_text(build_tilted_square_hero(), encoding="utf-8")
    print(f"Wrote {hero_path} ({hero_path.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
