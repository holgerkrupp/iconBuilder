# IconBuilder

A small native macOS (SwiftUI) app that reads Apple **Icon Composer `.icon`**
bundles, draws the icon from its `icon.json` definition, lets you apply
**iOS 26 / iOS 27** rendering recipes, and exports **vector PDF in CMYK** for print.

![light + dark](docs/preview.png)

## What it does

- **Parses `.icon` bundles** — the `icon.json` manifest (groups, layers,
  positions, fills, opacity, blend modes) with full **appearance
  specialization** resolution (`light` / `dark` / `tinted` / `clear`).
- **Renders faithfully** — each asset SVG is parsed to a `CGPath` (the app has
  its own dependency-free SVG-shape + path parser) and composited with the
  manifest's coordinate math, `automatic-gradient` fills, shadows and glass.
  The same render code drives both the on-screen preview and every export, so
  it is WYSIWYG.
- **Recipes (OS masking + effects)** — `iOS 26`, `iOS 27` and `watchOS`
  presets control the mask shape (squircle / circle), corner and superellipse
  geometry, layer shadow, glass specular and edge bezel. Every value is
  editable in the inspector.
- **Export**
  - **Vector PDF** in **DeviceCMYK** — paths and gradients stay vector
    (`ShadingType 2` axial shadings, no raster images), ready for print. Turn
    off cosmetic effects for a clean separation.
  - **PNG** (sRGB) for on-screen use.

> Coordinate model note: the manifest places layers on a 1024‑pt canvas with a
> center origin, Y‑up. This is reconstructed from the format and exposed in the
> renderer; it matches Icon Composer for the primary content. If a specific
> document's decorative layers differ, tune the recipe in the inspector.
>
> The **iOS 27** preset is a starting point (rounder mask, stronger glass) —
> adjust the sliders to the shipping spec.

## Build & run

Requires macOS 14+ and a recent Swift/Xcode toolchain.

```bash
# Run directly (SwiftPM)
swift run IconBuilder /path/to/YourIcon.icon

# …or build a double-clickable app bundle (associates with .icon files)
./make-app.sh            # debug
./make-app.sh --release  # optimized
open IconBuilder.app --args /path/to/YourIcon.icon
```

Open it in **Xcode** with `open Package.swift`.

## Usage

1. **Open** an `.icon` (toolbar button, ⌘O, drag-and-drop, or launch argument).
2. Pick an **appearance** (bottom bar) and a **recipe** (inspector); tune mask
   and effects live.
3. **Export PDF** (⌘E) — set point size, keep *DeviceCMYK* on for print.
   **Export PNG** (⇧⌘E) for raster.

## Project layout

```
Sources/IconBuilderCore/   Parsing, rendering, CMYK export (no dependencies)
  Model.swift              Codable icon.json model + appearance specialization
  SVGPath.swift            SVG path `d` → CGPath
  SVGShape.swift           SVG element/transform walker → single CGPath
  IconDocument.swift       .icon bundle loader
  Recipe.swift             OS masking/effects presets + mask geometry
  ColorConvert.swift       sRGB / Display-P3 → CMYK, gradient synthesis
  IconRenderer.swift       Shared compositor (preview == export)
  Exporters.swift          Vector CMYK PDF, PNG, in-memory PDF, rasterize
Sources/IconBuilder/       SwiftUI app (preview, inspector, export sheet)
Sources/rendertool/        Headless render harness (PNG/PDF) for validation
Tests/                     Parser / color / SVG unit tests
```

## Verifying the CMYK PDF

```bash
swift run rendertool /path/to/YourIcon.icon ./out
# → out/*.png previews and out/ios26-light-cmyk.pdf
```

The exported PDF uses an ICC‑based DeviceCMYK color space and vector axial
shadings — open it in Preview/Acrobat and check *Tools ▸ Show Inspector* or run
it through your print workflow's separations preview.
