import Foundation
import CoreGraphics

public struct RenderOptions: Sendable {
    public var appearance: Appearance
    public var recipe: Recipe
    /// Draw fills in DeviceCMYK (true) or sRGB (false).
    public var cmyk: Bool
    /// Cosmetic screen effects (soft shadows, specular gloss). Turn OFF for a
    /// clean, fully-vector print export.
    public var effects: Bool
    /// Fill the recipe's background behind the layers.
    public var background: Bool
    /// Clip the composition to the recipe's mask shape.
    public var clipToMask: Bool
    /// ICC output profile for CMYK conversion (nil = built-in formula).
    public var printProfile: PrintProfile?
    /// Use PDF-compatible constant-alpha bands for transparency gradients.
    /// Quartz PDF shadings do not preserve per-stop alpha.
    public var vectorPDF: Bool

    public init(appearance: Appearance = .light, recipe: Recipe = .iOS26,
                cmyk: Bool = false, effects: Bool = true,
                background: Bool = true, clipToMask: Bool = true,
                printProfile: PrintProfile? = nil, vectorPDF: Bool = false) {
        self.appearance = appearance; self.recipe = recipe; self.cmyk = cmyk
        self.effects = effects; self.background = background; self.clipToMask = clipToMask
        self.printProfile = printProfile; self.vectorPDF = vectorPDF
    }
}

/// Draws an `IconDocument` into a `CGContext`. Used identically for on-screen
/// bitmap preview and for vector PDF export, so what you see is what you print.
public enum IconRenderer {

    /// The authoring canvas Icon Composer uses.
    public static let authoringSize: CGFloat = 1024

    public static func render(_ doc: IconDocument, into ctx: CGContext,
                              size S: CGFloat, options: RenderOptions) {
        ctx.saveGState()
        // Work in a top-left origin, Y-down space (matches SVG + our math).
        ctx.translateBy(x: 0, y: S)
        ctx.scaleBy(x: 1, y: -1)

        let rect = CGRect(x: 0, y: 0, width: S, height: S)
        let mask = options.recipe.maskPath(in: rect)

        ctx.saveGState()
        if options.clipToMask {
            ctx.addPath(mask)
            ctx.clip()
        }

        // Background.
        if options.background {
            drawBackground(doc, ctx: ctx, rect: rect, options: options)
        }

        // The manifest lists groups topmost-first (Icon Composer sidebar order),
        // so draw back-to-front by iterating in reverse.
        for group in doc.manifest.groups.reversed() where !group.hidden {
            drawGroup(group, doc: doc, ctx: ctx, size: S, options: options)
        }

        // Cosmetic glass effects on top (screen only, or opt-in).
        // Liquid-glass lighting on the icon's own edge (calibrated against
        // Icon Composer 2.0 exports): bright top rim, cool bottom glow, subtle
        // side shading. Pure vector alpha strokes — safe in CMYK PDF export.
        if options.effects {
            EdgeLight.draw(on: mask, ctx: ctx, size: S, style: .iconMask, options: options)
        }

        ctx.restoreGState()   // mask clip
        ctx.restoreGState()   // flip
    }

    // MARK: - Layers

    private static func drawGroup(_ group: Group, doc: IconDocument, ctx: CGContext,
                                  size S: CGFloat, options: RenderOptions) {
        // Layers are also listed topmost-first.
        for layer in group.layers.reversed() where !layer.hidden {
            let opacity = layer.opacity.value(for: options.appearance) ?? 1.0
            if opacity <= 0.001 { continue }

            // Raster layers (PNG/JPEG assets) draw as images with the same
            // coordinate model; fills don't apply to them.
            if doc.shapes[layer.imageName] == nil {
                if let image = doc.images[layer.imageName] {
                    drawRasterLayer(image, layer: layer, group: group, ctx: ctx,
                                    size: S, options: options)
                }
                continue
            }
            let shape = doc.shapes[layer.imageName]!

            let fill = layer.fill.value(for: options.appearance) ?? .automatic
            if case .none = fill { continue }

            // Icon Composer coordinate model (calibrated against Icon Composer 2.0
            // reference exports): center origin, Y-DOWN, per node p' = (p−512)·s + t.
            // SVG(0..1024) → centered → layer → group → recentered → output scale.
            var m = layerCanvasTransform(layer: layer, group: group, outputSize: S)

            guard let canvasPath = shape.path.copy(using: &m) else { continue }

            if ProcessInfo.processInfo.environment["ICONDEBUG"] != nil {
                let b = canvasPath.boundingBoxOfPath
                FileHandle.standardError.write(Data("    layer \(layer.name) img=\(layer.imageName) op=\(opacity) -> bbox \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))\n".utf8))
            }

            let isGlass = layer.glass.value(for: options.appearance) ?? false
            let translucency = group.translucency.value(for: options.appearance)
            let translucent = isGlass && (translucency?.enabled ?? false)
            let translucencyAmount = CGFloat(translucency?.value ?? 0.5)
            let lighting = group.lighting.value(for: options.appearance)
            let raised = options.recipe.id == "ios26"
                && !isGlass
                && group.specular != false
                && lighting != "combined"
                && (translucency?.enabled ?? false)

            // Very subtle vector drop shadow around the shape (reference shows
            // ~2% darkening within a tight band; drawn without CG blur so it
            // stays vector and mirrors correctly).
            if (isGlass || raised), options.effects, let sh = group.shadow, sh.opacity > 0 {
                drawVectorShadow(on: canvasPath, ctx: ctx, size: S,
                                 strength: CGFloat(sh.opacity) * CGFloat(options.recipe.layerShadowOpacity),
                                 raised: raised, options: options)
            }

            ctx.saveGState()
            // Glass folds the layer opacity into its own alpha ramp (setAlpha
            // cannot compose with the banded translucency fill).
            ctx.setAlpha(translucent ? 1 : CGFloat(opacity))
            ctx.setBlendMode(blendMode(layer.blendMode.value(for: options.appearance)))
            paint(fill: fill, path: canvasPath, ctx: ctx, options: options,
                  glass: translucent, layerAlpha: CGFloat(opacity),
                  glassTranslucency: translucencyAmount, raised: raised)
            ctx.restoreGState()

            // Liquid-glass edge lighting (cosmetic). The group's `specular`
            // flag gates it, matching Icon Composer's Liquid Glass inspector.
            if isGlass && options.effects && (group.specular ?? true) {
                EdgeLight.draw(on: canvasPath, ctx: ctx, size: S, style: .glassLayer, options: options)
            } else if raised && options.effects {
                EdgeLight.draw(on: canvasPath, ctx: ctx, size: S, style: .raisedLayer, options: options)
            }
        }
    }

    /// Draw a raster asset layer using the standard coordinate model. The
    /// authoring canvas is 1024 pt; the image maps onto it like an SVG viewBox.
    private static func drawRasterLayer(_ image: CGImage, layer: Layer, group: Group,
                                        ctx: CGContext, size S: CGFloat,
                                        options: RenderOptions) {
        let m = layerCanvasTransform(layer: layer, group: group, outputSize: S)

        ctx.saveGState()
        ctx.setAlpha(CGFloat(layer.opacity.value(for: options.appearance) ?? 1))
        ctx.setBlendMode(blendMode(layer.blendMode.value(for: options.appearance)))
        ctx.concatenate(m)
        // The surrounding render context is Y-flipped (top-left origin);
        // un-flip locally so the image draws upright.
        ctx.translateBy(x: 0, y: authoringSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        if options.cmyk, let profile = options.printProfile {
            ctx.setRenderingIntent(profile.intent)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: authoringSize, height: authoringSize))
        ctx.restoreGState()
    }

    /// Fill a path according to a resolved fill value. `glass` renders the
    /// Liquid Glass translucency profile (calibrated vs Icon Composer 2.0:
    /// lighter and nearly opaque at the top, more transparent toward the
    /// bottom so the backdrop shows through).
    private static func paint(fill: Fill, path: CGPath, ctx: CGContext,
                              options: RenderOptions, glass: Bool = false,
                              layerAlpha: CGFloat = 1,
                              glassTranslucency: CGFloat = 0.5,
                              raised: Bool = false) {
        let box = path.boundingBoxOfPath
        switch fill {
        case .none:
            return
        case .automatic:
            // Ambiguous "inherit" — render as near-white so the shape is visible.
            ctx.addPath(path)
            ctx.setFillColor(ColorConvert.effectColor(
                r: 0.92, g: 0.92, b: 0.92, alpha: 1,
                cmyk: options.cmyk, profile: options.printProfile))
            ctx.fillPath(using: .evenOdd)
        case .solid(let color):
            gradientFill(base: color, topLift: 0, bottomLift: 0,
                         path: path, box: box, ctx: ctx, options: options,
                         glass: glass, flat: !glass, layerAlpha: layerAlpha,
                         glassTranslucency: glassTranslucency, raised: raised)
        case .automaticGradient(let base):
            gradientFill(base: base, topLift: 0.06, bottomLift: 0,
                         path: path, box: box, ctx: ctx, options: options,
                         glass: glass, flat: false, layerAlpha: layerAlpha,
                         glassTranslucency: glassTranslucency, raised: raised)
        case .linearGradient(let stops):
            if glass, let first = stops.first {
                // Glass with an explicit gradient: use its first stop as the base.
                gradientFill(base: first, topLift: 0.06, bottomLift: 0,
                             path: path, box: box, ctx: ctx, options: options,
                             glass: true, flat: false, layerAlpha: layerAlpha,
                             glassTranslucency: glassTranslucency, raised: raised)
            } else {
                explicitGradientFill(stops: stops, path: path, box: box, ctx: ctx, options: options)
            }
        }
    }

    /// Fill with an explicit multi-stop top→bottom gradient.
    private static func explicitGradientFill(stops: [ColorSpec], path: CGPath, box: CGRect,
                                             ctx: CGContext, options: RenderOptions) {
        guard !stops.isEmpty else { return }
        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        let colors = stops.map { ColorConvert.cgColor($0, cmyk: options.cmyk, profile: options.printProfile) }
        let locations = (0..<stops.count).map { CGFloat($0) / CGFloat(max(1, stops.count - 1)) }
        guard let grad = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                    locations: locations) else {
            ctx.addPath(path)
            ctx.setFillColor(colors[0])
            ctx.fillPath(using: .evenOdd)
            return
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Vertical gradient fill; for glass the stops also carry an alpha ramp.
    private static func gradientFill(base: ColorSpec, topLift: Double, bottomLift: Double, path: CGPath,
                                     box: CGRect, ctx: CGContext,
                                     options: RenderOptions, glass: Bool, flat: Bool,
                                     layerAlpha: CGFloat = 1,
                                     glassTranslucency: CGFloat = 0.5,
                                     raised: Bool = false) {
        if flat {
            ctx.addPath(path)
            ctx.setFillColor(ColorConvert.cgColor(base, cmyk: options.cmyk, profile: options.printProfile))
            ctx.fillPath(using: .evenOdd)
            return
        }
        if glass {
            // Icon Composer keeps the authored fill almost fully opaque through
            // most of a glass layer, then lets more of the backdrop through near
            // the lower edge. One alpha-bearing gradient keeps that transition
            // continuous; horizontal approximation bands leave visible seams.
            let translucency = max(0, min(1, Double(glassTranslucency)))
            var material = ColorConvert.inDisplayP3(base)
            material.r = max(0, material.r - 0.067)
            material.g = max(0, material.g - 0.004)
            material.b = max(0, material.b - 0.024)

            var upper = ColorConvert.adjusted(material, by: topLift * 0.10)
            var upperMiddle = material
            var middle = material
            var lower = material
            upper.a = Double(layerAlpha)
            upperMiddle.r *= 0.78
            upperMiddle.g *= 0.99
            upperMiddle.a = Double(layerAlpha) * (1 - 0.18 * translucency)
            middle.r *= 0.50
            middle.g *= 0.98
            middle.a = Double(layerAlpha) * (1 - 0.40 * translucency)
            lower.r *= 0.08
            lower.g *= 0.92
            lower.b *= 0.99
            lower.a = Double(layerAlpha) * (1 - 0.88 * translucency)

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
            let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
            let colors = [upper, upper, upperMiddle, middle, lower]
            let locations = [0.0, 0.18, 0.38, 0.55, 1.0]
            if options.vectorPDF {
                drawPDFAlphaGradient(colors: colors, locations: locations,
                                     box: box, ctx: ctx, options: options)
            } else {
                let gradColors = colors.map {
                    ColorConvert.cgColor($0, cmyk: options.cmyk, profile: options.printProfile)
                }
                if let grad = CGGradient(colorsSpace: space, colors: gradColors as CFArray,
                                         locations: locations.map { CGFloat($0) }) {
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: box.midX, y: box.minY),
                                       end: CGPoint(x: box.midX, y: box.maxY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            ctx.restoreGState()
            return
        }

        if raised {
            let material = raisedMaterialColor(base)
            let top = raisedMaterialTop(material)
            let bottom = raisedMaterialBottom(material)
            let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
            let colors = [top, material, bottom].map {
                ColorConvert.cgColor($0, cmyk: options.cmyk, profile: options.printProfile)
            }
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                         locations: [0, 0.50, 1]) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip(using: .evenOdd)
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: box.midX, y: box.minY),
                                       end: CGPoint(x: box.midX, y: box.maxY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }
            return
        }

        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        let top = ColorConvert.offset(base, by: topLift)
        let bottom = ColorConvert.adjusted(base, by: bottomLift)
        let colors = [ColorConvert.cgColor(top, cmyk: options.cmyk, profile: options.printProfile),
                      ColorConvert.cgColor(bottom, cmyk: options.cmyk, profile: options.printProfile)]
        guard let grad = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                    locations: [0, 1]) else {
            ctx.addPath(path)
            ctx.setFillColor(ColorConvert.cgColor(base, cmyk: options.cmyk, profile: options.printProfile))
            ctx.fillPath(using: .evenOdd)
            return
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// PDF axial shadings cannot vary opacity. Apply the opacity ramp as a
    /// grayscale image mask, then draw one opaque color shading through it.
    private static func drawPDFAlphaGradient(colors: [ColorSpec], locations: [Double],
                                             box: CGRect, ctx: CGContext,
                                             options: RenderOptions) {
        guard colors.count == locations.count, colors.count >= 2 else { return }

        func sample(_ t: Double) -> ColorSpec {
            var index = colors.count - 2
            for i in 0..<(locations.count - 1) where t <= locations[i + 1] {
                index = i
                break
            }
            let start = locations[index], end = locations[index + 1]
            let amount = end > start ? max(0, min(1, (t - start) / (end - start))) : 0
            var color = colors[index]
            let next = colors[index + 1]
            color.r += (next.r - color.r) * amount
            color.g += (next.g - color.g) * amount
            color.b += (next.b - color.b) * amount
            color.a += (next.a - color.a) * amount
            return color
        }

        let samples = 2048
        var maskBytes = [UInt8](repeating: 0, count: samples)
        for row in 0..<samples {
            // Image masks map bottom-up in a PDF context while renderer space
            // is top-down, so sample the opacity ramp in reverse row order.
            let t = 1 - (Double(row) + 0.5) / Double(samples)
            maskBytes[row] = UInt8((max(0, min(1, sample(t).a)) * 255).rounded())
        }
        let maskData = Data(maskBytes) as CFData
        guard let provider = CGDataProvider(data: maskData),
              let mask = CGImage(width: 1, height: samples,
                                 bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                                 space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent) else { return }

        let opaqueColors = colors.map { color -> CGColor in
            var opaque = color
            opaque.a = 1
            return ColorConvert.cgColor(
                opaque, cmyk: options.cmyk, profile: options.printProfile)
        }
        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        guard let gradient = CGGradient(colorsSpace: space, colors: opaqueColors as CFArray,
                                        locations: locations.map { CGFloat($0) }) else { return }

        ctx.saveGState()
        ctx.clip(to: box, mask: mask)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Soft shadow under a floating layer. A real Gaussian falloff avoids the
    /// concentric contour lines produced by approximating blur with strokes.
    private static func drawVectorShadow(on path: CGPath, ctx: CGContext,
                                         size S: CGFloat, strength: CGFloat,
                                         raised: Bool = false,
                                         options: RenderOptions) {
        guard strength > 0.01 else { return }
        ctx.saveGState()
        // Clip to everything *outside* the shape.
        ctx.setShouldAntialias(false)
        ctx.addRect(CGRect(x: -S, y: -S, width: 3 * S, height: 3 * S))
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.setShouldAntialias(true)
        let blur = raised
            ? S * 0.016
            : max(S * 0.006, S * CGFloat(options.recipe.layerShadowBlur) * 0.35)
        let alpha = raised ? min(0.16, strength * 0.80) : min(0.025, strength * 0.08)
        let shadowColor = ColorConvert.effectColor(
            r: 0, g: 0, b: 0, alpha: alpha,
            cmyk: options.cmyk, profile: options.printProfile)
        ctx.setShadow(offset: CGSize(width: 0, height: S * (raised ? 0.007 : 0.005)),
                      blur: blur, color: shadowColor)
        ctx.addPath(path)
        ctx.setFillColor(ColorConvert.effectColor(
            r: 0, g: 0, b: 0, alpha: 1,
            cmyk: options.cmyk, profile: options.printProfile))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private static func raisedMaterialColor(_ source: ColorSpec) -> ColorSpec {
        var color = ColorConvert.inDisplayP3(source)
        if color.r > 0.85, color.g > 0.80, color.b < 0.45 {
            // Icon Composer maps luminous yellow toward a printable gold.
            color.r *= 0.82; color.g *= 0.64; color.b *= 0.62
        } else if color.g > color.r * 1.45, color.g > color.b * 1.45 {
            // Highly luminous greens are normalized to the material's lightness.
            color.r *= 0.84; color.g *= 0.84; color.b *= 0.84
        } else if color.r > 0.75, color.g < 0.50 {
            color.r *= 0.98; color.g = min(1, color.g * 0.98 + 0.015)
            color.b = min(1, color.b * 0.98 + 0.020)
        } else if color.b > color.r * 1.40, color.b > color.g * 1.40 {
            color.r = min(1, color.r + 0.020)
            color.g = min(1, color.g + 0.030)
            color.b *= 0.995
        } else {
            color.g *= 0.99; color.b *= 0.99
        }
        return color
    }

    private static func raisedMaterialTop(_ material: ColorSpec) -> ColorSpec {
        var color = material
        if color.r > 0.70, color.g > 0.55, color.b < 0.35 {
            color.r = min(1, color.r + 0.10)
            color.g = min(1, color.g + 0.13)
            color.b = min(1, color.b + 0.06)
        } else if color.g > color.r * 1.45, color.g > color.b * 1.45 {
            color.r = min(1, color.r + 0.05)
            color.g = min(1, color.g + 0.075)
            color.b = min(1, color.b + 0.04)
        } else if color.r > 0.75, color.g < 0.50 {
            color.r = min(1, color.r + 0.16)
            color.g = min(1, color.g + 0.18)
            color.b = min(1, color.b + 0.19)
        } else {
            color = ColorConvert.offset(color, by: 0.16)
        }
        return color
    }

    private static func raisedMaterialBottom(_ material: ColorSpec) -> ColorSpec {
        var color = material
        if color.r > 0.70, color.g > 0.55, color.b < 0.35 {
            color.r *= 0.92; color.g *= 0.87; color.b *= 0.75
        } else if color.g > color.r * 1.45, color.g > color.b * 1.45 {
            color.r *= 0.85; color.g *= 0.87; color.b *= 0.75
        } else if color.r > 0.75, color.g < 0.50 {
            color.r *= 0.97; color.g *= 0.94; color.b *= 0.93
        } else {
            color.r *= 0.98; color.g *= 0.94; color.b *= 0.96
        }
        return color
    }

    // MARK: - Background

    private static func drawBackground(_ doc: IconDocument, ctx: CGContext,
                                       rect: CGRect, options: RenderOptions) {
        // Explicit document gradient: use its stops directly.
        if case .linearGradient(let stops) = doc.manifest.fill, stops.count >= 2 {
            let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
            let colors = stops.map { ColorConvert.cgColor($0, cmyk: options.cmyk, profile: options.printProfile) }
            let locations = (0..<stops.count).map { CGFloat($0) / CGFloat(stops.count - 1) }
            if let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) {
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY),
                                       end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
                ctx.restoreGState()
                return
            }
        }
        let top: ColorSpec
        let bottom: ColorSpec
        let base: ColorSpec
        switch doc.manifest.fill {
        case .solid(let c), .automaticGradient(let c):
            base = c
            top = ColorConvert.adjusted(base, by: 0.06)
            bottom = ColorConvert.adjusted(base, by: -0.06)
        default:
            base = options.appearance == .dark
                ? options.recipe.defaultDarkBackground
                : options.recipe.defaultBackground
            // Reference exports show a pronounced relative top→bottom falloff on
            // the automatic background (49→34→20 /255 in the iOS 26 dark export).
            top = ColorConvert.scaled(base, by: 1.44)
            bottom = ColorConvert.scaled(base, by: 0.59)
        }
        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        if let grad = CGGradient(colorsSpace: space,
                                 colors: [ColorConvert.cgColor(top, cmyk: options.cmyk, profile: options.printProfile),
                                          ColorConvert.cgColor(bottom, cmyk: options.cmyk, profile: options.printProfile)] as CFArray,
                                 locations: [0, 1]) {
            // Clip to the canvas rect: a linear gradient otherwise floods the
            // entire clip region, which leaks outside the canvas when the
            // caller renders unclipped (print bleed tiles).
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
        } else {
            ctx.setFillColor(ColorConvert.cgColor(base, cmyk: options.cmyk, profile: options.printProfile))
            ctx.fill(rect)
        }
    }

    // MARK: - Cosmetic effects

    // MARK: - Helpers

    /// The exact transform used to place an SVG asset into the final rendered
    /// icon. The shape editor uses this too, so its handles line up with the
    /// composed layer even when both the layer and its group are transformed.
    public static func layerCanvasTransform(layer: Layer, group: Group,
                                            outputSize: CGFloat = authoringSize) -> CGAffineTransform {
        let k = outputSize / authoringSize
        let centered = CGAffineTransform(translationX: -authoringSize / 2,
                                         y: -authoringSize / 2)
        let layerTransform = affine(scale: layer.position.scale,
                                    tx: layer.position.tx, ty: layer.position.ty)
        let groupTransform = affine(scale: group.position.scale,
                                    tx: group.position.tx, ty: group.position.ty)
        let output = CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                       tx: authoringSize / 2 * k,
                                       ty: authoringSize / 2 * k)
        return centered.concatenating(layerTransform).concatenating(groupTransform).concatenating(output)
    }

    private static func affine(scale: Double, tx: Double, ty: Double) -> CGAffineTransform {
        CGAffineTransform(a: CGFloat(scale), b: 0, c: 0, d: CGFloat(scale),
                          tx: CGFloat(tx), ty: CGFloat(ty))
    }

    private static func blendMode(_ name: String?) -> CGBlendMode {
        switch name {
        case "multiply": return .multiply
        case "screen": return .screen
        case "overlay": return .overlay
        case "softlight", "soft-light": return .softLight
        case "hardlight", "hard-light": return .hardLight
        case "lighten": return .lighten
        case "darken": return .darken
        case "color-dodge": return .colorDodge
        case "color-burn": return .colorBurn
        default: return .normal
        }
    }
}
