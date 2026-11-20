# Pervigil brand assets

The mark is pure geometry, so the vector is the only source of truth. Everything
else (PNG mockups, app icon layers, menu-bar glyphs) is rendered from it.

| File | What |
| --- | --- |
| `pervigil-mark.svg` | The mark, one path, `currentColor` fill (175 bytes). |
| `pervigil-mark-blue.svg` | The mark with the brand gradient baked in. |

## Geometry

`viewBox 0 0 562 650`. A solid block with two cuts:

- a notch on the left edge, from `(0,124)` down the 29.4° diagonal to `(190,231)`
- a play triangle `(190,231) (557,438) (190,645)`, so the left bar is 190 wide

The diagonal of the notch and the top edge of the triangle are one line.

## Colorways

| Name | Mark | Background |
| --- | --- | --- |
| Blue | `#6EAFF6` to `#007AFF` (top to bottom) | `#F4F4F4` |
| On blue | `#FFFFFF` | `#69A9ED` to `#2D8EF9` |
| Light | `#000000` | `#EEEEEE` to `#CACACA` |
| Dark | `#FFFFFF` | `#171717` to `#010101` |

## Keeping images out of the repo

- Commit vectors and tokens, not renders. A 2000 px PNG of this mark is 1 to 4 MB;
  the SVG is under 1 KB and renders at any size.
- In the app, draw the mark as a SwiftUI `Shape` (the same polygons) instead of
  bundling bitmaps. It stays crisp at menu-bar size, tints as a template glyph,
  and can animate.
- Raw design exports (Figma frames, social mockups) live outside git. If a
  bitmap must be versioned, export it at the size it is shown, as WebP or an
  optimized PNG, or track it with Git LFS.
