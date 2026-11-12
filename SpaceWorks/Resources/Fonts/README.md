# Native Space Works fonts

The app follows the 0.12.0 Design-Kit typography (`design/fonts/README.md`, `design/docs/ui-brand-spec.md`)
with **open-licensed fonts only** (owner decision 2026-11-13):

| Role | Face | Where |
| --- | --- | --- |
| Interface and body text | Outfit (variable, 400–700 used; heavier under Bold Text) | `brandFont(_:)` for every style |
| Display headings | Outfit ExtraBold (800) | `brandFont(.largeTitle/.title/.title2, weight: .bold)` |
| Light display text | Outfit Light (300) | `brandFont(_, weight: .light)` on display styles |
| One short accent phrase per screen | Unbounded (variable) | `BrandTypography.accent(_:)` |

No font file is committed. `scripts/generate.py` (via `scripts/brand_fonts.py`) decompresses the kit's
Outfit and Unbounded WOFF2 files from the pinned `design/` submodule into `SpaceWorks/Generated/Fonts/` and
registers them through `UIAppFonts`. WOFF2 is a compressed container: decompression restores the font's own
tables; names, outlines and metrics are unchanged. It needs fontTools with Brotli (`brew install fonttools`,
or `python3 -m pip install fonttools brotli`). Converted files are cached by source hash in
`.build/font-stamp.json`, so the Xcode pre-build phase reuses them even when its Python lacks fontTools.

Both fonts are variable and their named instances carry no PostScript names, so a weight is the
registered default face (`Outfit-Thin`, `Unbounded-Regular`) plus an exact `wght` axis value
(`BrandTypography.Face`), never an instance name. Every face keeps Dynamic Type through `UIFontMetrics`
(SwiftUI recomputes it from the environment's text size), and Bold Text selects a heavier Outfit weight. Native navigation titles and system controls keep platform typography.
IDs and codes use Outfit Medium with tabular digits.

## Licences

- Outfit and Unbounded: SIL Open Font License 1.1. `OFL-Outfit.txt` and `OFL-Unbounded.txt` are copied
  from `design/fonts/LICENSES/` into the app bundle beside the fonts.
- Gilroy is not open-licensed. The kit's Gilroy files are never converted, bundled or committed, and
  `scripts/audit_bundle.py` fails a Release bundle that contains any Gilroy file.

The Space Works logo masters are outlined artwork and do not use these fonts at runtime.
