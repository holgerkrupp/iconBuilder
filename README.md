# IconBuilder

IconBuilder uses the shared ShapeEditingKit workspace language: layers and groups on the left, the final-look canvas with the shared shape toolbar in the center, and icon-specific properties on the right.

Its macOS menus add Command–O import, Command–S save back to Icon Composer, Command–Shift–S editable `.icon` export, Command–Shift–E PDF export, Command–Option–E PNG export, Command–Option–P print-ready PDF export, Command–Shift–G new group, and Command–Return shape editing alongside the shared Shape and View commands. A first-launch walkthrough and full reference are always available from the Help menu.

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
  presets control the mask shape and effects. The default **Apple (measured)**
  mask is Apple's exact icon contour, extracted from a 4096 px Icon Composer
  export (worst deviation 0.5 px at 1024 vs the alpha edge; the parametric
  superellipse deviated up to 5 px at the corners — visible against the
  die-cut line). Superellipse / circle / rounded-rect remain available, with
  corner and exponent sliders, plus layer shadow, glass specular and edge
  bezel controls. Every value is
  editable in the inspector. Presets are calibrated against Icon Composer 2.0
  reference exports (mask geometry is identical between 26 and 27; they differ
  in glass/rim lighting strength and dark-appearance background).
- **Per-layer / per-group editing** — an Icon Composer-style sidebar tree and
  contextual inspector: select the document, a group, or a single layer and
  edit its properties for the currently previewed appearance. This includes
  document and layer fills (automatic, none, solid, automatic gradient, and
  editable multi-stop linear gradients), opacity, blend modes, Liquid Glass,
  blur material, lighting, specular, translucency, refractivity, shadow,
  visibility, layout, names, asset references, and supported platforms. An
  **Apply Recipe** menu applies the iOS 26 / iOS 27 glass defaults to whatever
  is selected.
- **SVG shape editor** — add rectangles, rounded rectangles, circles, ellipses,
  lines, curves, triangles, diamonds, stars, and arrows as new layers. Existing
  SVG layers can be moved and resized with canvas handles or precise
  x/y/width/height fields. The compact edit row provides the same shape library,
  SVG import, undo/redo, and alignment-guide workflow as SymbolBuilder. Shapes
  snap to the canvas and other artwork's edges and centers (hold ⌘ to bypass),
  and multi-selected vector layers can be combined with Union, Subtract,
  Intersect, or Exclude Overlap.
  New and modified geometry is stored as SVG in the working copy's `Assets`
  folder; untouched source SVGs are not rewritten. Edits are **autosaved** to
  the library copy about a second after you stop working — there is no save
  step to remember, and nothing to lose on quit or crash.
  Shared advanced editing includes direct Bézier nodes and pen paths, text (including
  multiline, variable axes, text-on-path, and outline conversion), rotation/skew/
  perspective transforms, stroke caps/joins/dashes/markers, compound paths and masks,
  offsets/corner rounding/simplification, exact alignment/distribution, custom guides,
  grids and measurements, and repeat/mirror operations. Text is rendered to vector
  glyph outlines, so it participates in the same Boolean operations as other shapes.
- **Layer organization** — Command-click layers to select several, then use
  Boolean operations or delete them together. Drag layers in the sidebar to
  reorder them, or drop them on another group to move them across groups.
- **Export**
  - **Vector PDF** in **DeviceCMYK** — paths and gradients stay vector
    (`ShadingType 2` axial shadings, no raster images), ready for print. Turn
    off cosmetic effects for a clean separation.
  - **Print-ready PDF** (⌥⌘P) — physical target size in mm plus configurable
    **bleed** (default 3 mm). The page is target + 2×bleed with the PDF
    **TrimBox** on the finished size and **BleedBox** on the page; artwork
    bleeds to the page edge (page-size underlay, exact artwork on the trim);
    the die-cut contour follows the recipe's mask as a **`/Separation`
    spot color named `CutContour`** (100% magenta alternate) on its own
    **PDF layer (OCG) named `CutContour`** — the structure Roland
    VersaWorks-style RIPs and most sticker/die-cut services expect. The
    bleed is **seamless**: the artwork's true continuation fills it
    (the square canvas extends past the mask), with edge-mirroring for
    the sliver beyond the canvas — no scaled, misaligned underlay.
    Optionally **flatten** the artwork to a CMYK bitmap at a chosen
    resolution (default 300 dpi) for shops that require flattened files —
    the cut line stays vector either way.
  - **PNG** (Display P3) for on-screen use and Icon Composer parity.
- **ICC-profile CMYK** — import your print service's output profile
  (e.g. `ISOcoated_v2_300_eci.icc` / FOGRA39) in the export sheets; all CMYK
  exports and the CMYK preview then convert through the profile (rendering
  intent selectable: saturation for vivid artwork, perceptual, relative
  colorimetric) and the profile is embedded in the PDF as ICCBased color.
  The choice persists across launches. Without a profile, a built-in
  light-GCR formula conversion is used.
- **Hybrid artwork (100% Icon Composer match)** — the print export can place
  an **Icon Composer PNG export** over the trim area (Artwork → Choose PNG),
  giving a pixel-exact match with Apple's own render including backdrop blur;
  the vector artwork still fills the bleed, the seam falls on the cut line,
  and in CMYK mode the PNG is flattened through the selected ICC profile.
- **RGB output** — the print-ready export can alternatively emit **sRGB**
  artwork (Color: RGB in the export sheet) for print services that prefer
  RGB input and convert with their own profiles; the full screen gamut is
  preserved and the CutContour spot layer stays intact. The plain vector
  PDF export likewise supports RGB by disabling its CMYK toggle.

> Coordinate model: the manifest places layers on a 1024‑pt canvas with a
> center origin and **Y‑down** translations, `p' = (p − 512)·scale + t` per
> layer then per group; groups and layers are listed **topmost-first**. This
> was calibrated pixel-exact against Icon Composer 2.0 exports (stripe seams
> within ~2 px, glass-shape geometry within 2 px at 1024).

## Build & run

Requires macOS 26+ and Xcode 26 or newer. The interface uses the native Liquid Glass APIs.

```bash
# Xcode (recommended): open the project, ⌘R to run, ⌘U for tests
open IconBuilder.xcodeproj

# Build a double-clickable app bundle (associates with .icon files)
./make-app.sh            # debug
./make-app.sh --release  # optimized
open -a "$PWD/IconBuilder.app" /path/to/YourIcon.icon
```

`IconBuilder.xcodeproj` is the only build system — there is no Swift package.
The app target compiles all of `Sources/IconBuilder` (including `Core/`) as one
module via a synchronized folder. `IconBuilderCoreTests` is a host-app test
bundle that reaches in with `@testable import IconBuilder`, and `rendertool` is
a command-line target that compiles the `Core/` sources directly alongside its
own `main.swift`. CLI builds:

```bash
xcodebuild -project IconBuilder.xcodeproj -scheme IconBuilder build
xcodebuild -project IconBuilder.xcodeproj -scheme IconBuilder test
xcodebuild -project IconBuilder.xcodeproj -scheme rendertool build
```

## Usage

1. **Import** an `.icon` (toolbar button, ⌘O, drag-and-drop, or launch
   argument). It is copied into the IconBuilder library; your original is not
   touched until you explicitly write back to it.
2. Pick an **appearance** (bottom bar) and a **recipe** (inspector); tune mask
   and effects live.
3. Select a layer to edit all of its values, or choose **Add** to create an SVG
   shape. Selecting a vector layer shows its move and resize controls on the canvas. Your work
   is autosaved as you go.
4. **Save Back to Icon Composer** (⌘S) writes the working copy over the
   original bundle, or **Export Editable .icon…** (⇧⌘S) writes it anywhere you
   choose. Both require Pro.
5. **Export PDF** (⇧⌘E) — set point size and choose CMYK or RGB.
   **Export PNG** (⌥⌘E) for raster, or **Print-Ready PDF** (⌥⌘P) for
   physical sizing, bleed, and an optional CutContour spot-color layer. All
   three require Pro.

## Opening .icon files from Finder

IconBuilder declares Apple's `com.apple.iconcomposer.icon` type, so it appears
under Finder's **Open With** for any `.icon` bundle. Icon Composer, as the
type's owner, stays the default — IconBuilder offers itself rather than
claiming the association.

To make the change permanent, use Finder: select a `.icon` bundle, **File ▸ Get
Info**, pick IconBuilder under "Open with:", then **Change All…**. macOS asks
for confirmation, as it does for any default-app change.

The type is *imported*, not exported — IconBuilder does not own it — which keeps
the association working on a Mac without Xcode installed.

> An in-app "make IconBuilder the default" action is implemented in
> `IconTypeAssociation` but deliberately not wired up. It belongs in the planned
> Settings window rather than a menu item.

## Free and Pro

Editing is free; writing finished work out of the app is a one-time purchase
(**IconBuilder Pro**, a non-consumable, matching SymbolBuilder).

| Free | IconBuilder Pro |
| --- | --- |
| Import `.icon` bundles into the internal library | Save Back to Icon Composer (⌘S) |
| Full editing, recipes, and live preview | Export Editable `.icon…` (⇧⌘S) |
| Autosave, session restore, crash recovery | PDF / PNG / print-ready exports |

Autosave, recovery, quitting and crash restoration are **never** gated — work
you have done stays yours and stays reachable whether or not you buy Pro. The
Pro requirement is disclosed up front, right after import, so nobody designs an
icon before learning what writing it out costs. The paywall is raised on
choosing a gated action, always before any save panel appears, and gated menu
and toolbar items carry a small `PRO` badge.

**Restore Purchases** lives in the paywall, which is also reachable any time
from **IconBuilder ▸ IconBuilder Pro…**.

For local testing, `IconBuilder.storekit` configures the product
(`de.holgerkrupp.IconBuilder.pro`); select it as the scheme's StoreKit
configuration in Xcode. Setting `ICONBUILDER_NO_PAYWALL=1` in a run scheme
bypasses the gate for development.

## Automation (Shortcuts & Siri)

Every project in the library is exposed to Shortcuts, Spotlight and Siri through
App Intents, under the **Icons** category. Projects resolve by name, so "Preview
the Up Next icon with IconBuilder" works without the app being open.

| Action | Tier | Returns |
| --- | --- | --- |
| Open Icon Project | Free | — (opens the editor) |
| Render Icon Preview | Free | PNG, watermarked until Pro |
| Show IconBuilder Pro | Free | — (opens the purchase) |
| Export Icon as PDF | Pro | Vector PDF, optional DeviceCMYK |
| Export Icon as PNG | Pro | Full-resolution Display P3 PNG |
| Export Print-Ready PDF | Pro | Print PDF with bleed + CutContour |
| Save Back to Icon Composer | Pro | The written path |

Pro actions funnel through a single `ProGate.requireUnlocked()` check in
[`IconIntentSupport.swift`](Sources/IconBuilder/Intents/IconIntentSupport.swift),
so a new export action cannot accidentally ship ungated. Without the purchase
they fail with an explanation rather than emitting a partial or watermarked
file — a shortcut never silently writes something unusable, and the free
library, autosave and recovery are untouched either way.

Export actions flush the open editor before rendering, so an automation that
runs while you are working still sees what is on screen.

There is deliberately **no import action**: a `.icon` is a bundle (a folder) and
Shortcuts passes files rather than folders. Import through the app; automate
everything afterwards.

Choose **Help → Getting Started** to reopen the walkthrough or
**Help → IconBuilder Documentation** (⌘?) for the complete in-app guide.

## Project layout

```
Sources/IconBuilder/       The app — one module, one target
  Core/                    Parsing, rendering, and export core
    Model.swift            Codable icon.json model + appearance specialization
    EditableShape.swift    Parametric shapes + SVG path serialization
    IconDocument.swift     .icon bundle loader and saver
    Recipe.swift           OS masking/effects presets + mask geometry
    ColorConvert.swift     sRGB / Display-P3 → CMYK, gradient synthesis
    IconRenderer.swift     Shared compositor (preview == export)
    Exporters.swift        Vector CMYK PDF, PNG, in-memory PDF, rasterize
  Library/                 Internal project library + autosave
  Store/                   StoreKit entitlement and paywall
  Intents/                 App Intents for Shortcuts, Spotlight and Siri
  *.swift                  SwiftUI app, onboarding, documentation, export UI
Sources/rendertool/        Headless render harness (PNG/PDF) for validation
Tests/                     Parser, color, SVG, save, and export unit tests
```

## Verifying the CMYK PDF

```bash
xcodebuild -project IconBuilder.xcodeproj -scheme rendertool build
"$(xcodebuild -project IconBuilder.xcodeproj -scheme rendertool \
    -showBuildSettings 2>/dev/null |
    awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/rendertool" \
  /path/to/YourIcon.icon ./out
# → out/*.png previews and out/ios26-light-cmyk.pdf
```

The exported PDF uses an ICC‑based DeviceCMYK color space and vector axial
shadings — open it in Preview/Acrobat and check *Tools ▸ Show Inspector* or run
it through your print workflow's separations preview.
