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

    public init(appearance: Appearance = .light, recipe: Recipe = .iOS26,
                cmyk: Bool = false, effects: Bool = true,
                background: Bool = true, clipToMask: Bool = true) {
        self.appearance = appearance; self.recipe = recipe; self.cmyk = cmyk
        self.effects = effects; self.background = background; self.clipToMask = clipToMask
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

        // Groups back-to-front (JSON order is bottom → top).
        for group in doc.manifest.groups where !group.hidden {
            drawGroup(group, doc: doc, ctx: ctx, size: S, options: options)
        }

        // Cosmetic glass effects on top (screen only, or opt-in).
        if options.effects {
            drawSpecular(ctx: ctx, rect: rect, recipe: options.recipe)
            drawEdgeBezel(ctx: ctx, mask: mask, rect: rect, recipe: options.recipe)
        }

        ctx.restoreGState()   // mask clip
        ctx.restoreGState()   // flip
    }

    // MARK: - Layers

    private static func drawGroup(_ group: Group, doc: IconDocument, ctx: CGContext,
                                  size S: CGFloat, options: RenderOptions) {
        let k = S / authoringSize
        let g = affine(scale: group.position.scale, tx: group.position.tx, ty: group.position.ty)

        for layer in group.layers where !layer.hidden {
            guard let shape = doc.shapes[layer.imageName] else { continue }

            let opacity = layer.opacity.value(for: options.appearance) ?? 1.0
            if opacity <= 0.001 { continue }

            let fill = layer.fill.value(for: options.appearance) ?? .automatic
            if case .none = fill { continue }

            // SVG(0..1024,Y-down) → centered Y-up → layer → group → output(Y-down).
            let c2p = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -512, ty: 512)
            let l = affine(scale: layer.position.scale, tx: layer.position.tx, ty: layer.position.ty)
            let p2o = CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: 512 * k, ty: 512 * k)
            var m = c2p.concatenating(l).concatenating(g).concatenating(p2o)

            guard let canvasPath = shape.path.copy(using: &m) else { continue }

            if ProcessInfo.processInfo.environment["ICONDEBUG"] != nil {
                let b = canvasPath.boundingBoxOfPath
                FileHandle.standardError.write(Data("    layer \(layer.name) img=\(layer.imageName) op=\(opacity) -> bbox \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))\n".utf8))
            }

            ctx.saveGState()
            ctx.setAlpha(CGFloat(opacity))
            ctx.setBlendMode(blendMode(layer.blendMode.value(for: options.appearance)))

            // Layer drop shadow (from the group), screen effect only.
            if options.effects, let sh = group.shadow, sh.opacity > 0 {
                let blur = options.recipe.layerShadowBlur * S
                let shadowColor = CGColor(gray: 0, alpha: CGFloat(sh.opacity) * CGFloat(options.recipe.layerShadowOpacity))
                ctx.setShadow(offset: CGSize(width: 0, height: blur * 0.4), blur: blur, color: shadowColor)
            }

            paint(fill: fill, path: canvasPath, ctx: ctx, options: options)
            ctx.restoreGState()
        }
    }

    /// Fill a path according to a resolved fill value.
    private static func paint(fill: Fill, path: CGPath, ctx: CGContext, options: RenderOptions) {
        let box = path.boundingBoxOfPath
        switch fill {
        case .none:
            return
        case .automatic:
            // Ambiguous "inherit" — render as near-white so the shape is visible.
            ctx.addPath(path)
            ctx.setFillColor(options.cmyk
                ? CGColor(colorSpace: ColorConvert.cmykSpace, components: [0, 0, 0, 0.08, 1])!
                : CGColor(gray: 0.92, alpha: 1))
            ctx.fillPath(using: .evenOdd)
        case .solid(let color):
            ctx.addPath(path)
            ctx.setFillColor(ColorConvert.cgColor(color, cmyk: options.cmyk))
            ctx.fillPath(using: .evenOdd)
        case .automaticGradient(let base):
            // Synthesize Icon Composer's soft gradient from a single base color.
            let top = ColorConvert.adjusted(base, by: 0.12)
            let bottom = ColorConvert.adjusted(base, by: -0.12)
            let space = options.cmyk ? ColorConvert.cmykSpace : ColorConvert.rgbSpace
            let c0 = ColorConvert.cgColor(top, cmyk: options.cmyk)
            let c1 = ColorConvert.cgColor(bottom, cmyk: options.cmyk)
            guard let grad = CGGradient(colorsSpace: space, colors: [c0, c1] as CFArray,
                                        locations: [0, 1]) else {
                ctx.addPath(path); ctx.setFillColor(ColorConvert.cgColor(base, cmyk: options.cmyk))
                ctx.fillPath(using: .evenOdd); return
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
    }

    // MARK: - Background

    private static func drawBackground(_ doc: IconDocument, ctx: CGContext,
                                       rect: CGRect, options: RenderOptions) {
        let base: ColorSpec
        switch doc.manifest.fill {
        case .solid(let c), .automaticGradient(let c): base = c
        default: base = options.recipe.defaultBackground
        }
        let top = ColorConvert.adjusted(base, by: 0.06)
        let bottom = ColorConvert.adjusted(base, by: -0.06)
        let space = options.cmyk ? ColorConvert.cmykSpace : ColorConvert.rgbSpace
        if let grad = CGGradient(colorsSpace: space,
                                 colors: [ColorConvert.cgColor(top, cmyk: options.cmyk),
                                          ColorConvert.cgColor(bottom, cmyk: options.cmyk)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        } else {
            ctx.setFillColor(ColorConvert.cgColor(base, cmyk: options.cmyk))
            ctx.fill(rect)
        }
    }

    // MARK: - Cosmetic effects

    private static func drawSpecular(ctx: CGContext, rect: CGRect, recipe: Recipe) {
        guard recipe.specularHighlight, recipe.specularStrength > 0 else { return }
        let space = ColorConvert.rgbSpace
        let hi = CGColor(colorSpace: space, components: [1, 1, 1, CGFloat(recipe.specularStrength)])!
        let lo = CGColor(colorSpace: space, components: [1, 1, 1, 0])!
        guard let grad = CGGradient(colorsSpace: space, colors: [hi, lo] as CFArray,
                                    locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.softLight)
        ctx.drawRadialGradient(grad,
                               startCenter: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12),
                               startRadius: 0,
                               endCenter: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12),
                               endRadius: rect.width * 0.85, options: [])
        ctx.restoreGState()
    }

    private static func drawEdgeBezel(ctx: CGContext, mask: CGPath, rect: CGRect, recipe: Recipe) {
        guard recipe.edgeBezel > 0 else { return }
        ctx.saveGState()
        ctx.addPath(mask)
        ctx.setLineWidth(recipe.edgeBezel * rect.width)
        ctx.setStrokeColor(CGColor(colorSpace: ColorConvert.rgbSpace, components: [1, 1, 1, 0.18])!)
        ctx.setBlendMode(.overlay)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Helpers

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
