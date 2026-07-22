import Foundation
import CoreGraphics

/// Smooth inner highlights for the app-icon mask and Liquid Glass layers.
///
/// The highlight is built from a clipped gradient stroke. Keeping it continuous
/// avoids the curvature hot-spots and segment joins produced by a flattened path.
enum EdgeLight {

    struct Style {
        enum Kind {
            case glassLayer
            case iconMask
            case raisedLayer
        }

        var kind: Kind
        var coreWidth: CGFloat
        var glowWidth: CGFloat
        var coreStrength: CGFloat
        var glowStrength: CGFloat

        static let glassLayer = Style(
            kind: .glassLayer,
            coreWidth: 0.0023,
            glowWidth: 0.0080,
            coreStrength: 0.85,
            glowStrength: 0.14)

        static let iconMask = Style(
            kind: .iconMask,
            coreWidth: 0.0035,
            glowWidth: 0.0140,
            coreStrength: 0.58,
            glowStrength: 0.15)

        static let raisedLayer = Style(
            kind: .raisedLayer,
            coreWidth: 0.0120,
            glowWidth: 0.0340,
            coreStrength: 0.44,
            glowStrength: 0.14)
    }

    static func draw(on path: CGPath, ctx: CGContext, size S: CGFloat, style: Style,
                     options: RenderOptions) {
        guard options.recipe.specularHighlight else { return }

        if style.kind == .glassLayer, options.recipe.id == "ios26" {
            drawLegacyGlassBezel(path, ctx: ctx, size: S, options: options)
            return
        }

        if style.kind == .iconMask, options.recipe.id == "ios26" {
            drawLegacyMaskGlow(path, ctx: ctx, size: S, options: options)
            drawRim(path, ctx: ctx, size: S, width: S * 0.006,
                    strength: 0.18, kind: .iconMask, options: options)
            return
        }
        let tuned = style

        let recipeScale: CGFloat
        switch tuned.kind {
        case .glassLayer:
            recipeScale = 0.92 + CGFloat(options.recipe.specularStrength) * 0.35
        case .iconMask:
            recipeScale = 0.88 + CGFloat(options.recipe.specularStrength) * 0.28
        case .raisedLayer:
            recipeScale = 1
        }

        drawRim(path, ctx: ctx, size: S, width: tuned.glowWidth * S,
                strength: tuned.glowStrength * recipeScale,
                kind: tuned.kind, options: options)
        drawRim(path, ctx: ctx, size: S, width: tuned.coreWidth * S,
                strength: tuned.coreStrength * recipeScale,
                kind: tuned.kind, options: options)
        if tuned.kind == .raisedLayer {
            drawRaisedShade(path, ctx: ctx, size: S, options: options)
        }
    }

    private static func drawRim(_ path: CGPath, ctx: CGContext, size S: CGFloat,
                                width: CGFloat, strength: CGFloat, kind: Style.Kind,
                                options: RenderOptions) {
        guard width > 0, strength > 0 else { return }

        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        let stops: [(CGFloat, CGFloat, CGFloat)]
        let locations: [CGFloat]

        switch kind {
        case .glassLayer:
            // Keep one cyan hue throughout, varying only its intensity so the
            // right-hand tip remains neutral without introducing color shifts.
            stops = [(0.20, 1, 1), (0.20, 1, 1), (0, 0, 0),
                     (0, 0, 0), (0.20, 1, 1)]
            locations = [0, 0.14, 0.36, 0.72, 1]
        case .iconMask:
            stops = [(1, 1, 1), (0.05, 0.05, 0.05), (0, 0, 0), (0.30, 0.82, 1)]
            locations = [0, 0.18, 0.72, 1]
        case .raisedLayer:
            stops = [(1, 1, 1), (0.70, 0.70, 0.70), (0, 0, 0), (0, 0, 0)]
            locations = [0, 0.22, 0.62, 1]
        }

        let colors = stops.map {
            ColorConvert.effectColor(r: $0.0, g: $0.1, b: $0.2, alpha: 1,
                                     cmyk: options.cmyk, profile: options.printProfile)
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                        locations: locations) else { return }
        let box = path.boundingBoxOfPath

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.setBlendMode(.screen)
        ctx.setAlpha(strength)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawRaisedShade(_ path: CGPath, ctx: CGContext, size S: CGFloat,
                                        options: RenderOptions) {
        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        let colors = [(1.0, 1.0, 1.0), (1.0, 1.0, 1.0), (0.42, 0.42, 0.42)].map {
            ColorConvert.effectColor(r: $0.0, g: $0.1, b: $0.2, alpha: 1,
                                     cmyk: options.cmyk, profile: options.printProfile)
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                        locations: [0, 0.58, 1]) else { return }
        let box = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.addPath(path)
        ctx.setLineWidth(S * 0.020)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.setBlendMode(.multiply)
        ctx.setAlpha(0.34)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawLegacyGlassBezel(_ path: CGPath, ctx: CGContext, size S: CGFloat,
                                              options: RenderOptions) {
        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        let stops: [(CGFloat, CGFloat, CGFloat)] = [
            (0.68, 0.95, 0.60), (0.60, 0.70, 0.75), (0.38, 0.70, 0.90)]
        let colors = stops.map {
            ColorConvert.effectColor(r: $0.0, g: $0.1, b: $0.2, alpha: 1,
                                     cmyk: options.cmyk, profile: options.printProfile)
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                        locations: [0, 0.55, 1]) else { return }
        let box = path.boundingBoxOfPath

        drawSoftInnerGlow(path, ctx: ctx, size: S, maxInset: 0.026,
                          sigma: 0.012, peakAlpha: 0.18,
                          tint: (0.55, 0.80, 0.80), blendMode: .normal,
                          options: options)

        func stroke(_ width: CGFloat, alpha: CGFloat) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.setAlpha(alpha)
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: box.midX, y: box.minY),
                                   end: CGPoint(x: box.midX, y: box.maxY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }

        stroke(S * 0.012, alpha: 0.30)
    }

    private static func drawLegacyMaskGlow(_ path: CGPath, ctx: CGContext, size S: CGFloat,
                                           options: RenderOptions) {
        drawSoftInnerGlow(path, ctx: ctx, size: S, maxInset: 0.045,
                          sigma: 0.018, peakAlpha: 0.36,
                          tint: (1, 1, 1), blendMode: .screen,
                          options: options)
    }

    private static func drawSoftInnerGlow(
        _ path: CGPath, ctx: CGContext, size S: CGFloat,
        maxInset: CGFloat, sigma: CGFloat, peakAlpha: CGFloat,
        tint: (CGFloat, CGFloat, CGFloat), blendMode: CGBlendMode,
        options: RenderOptions
    ) {
        let bands = 64
        let box = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.setBlendMode(blendMode)

        for i in stride(from: bands, through: 1, by: -1) {
            let outerDistance = maxInset * CGFloat(i) / CGFloat(bands)
            let innerDistance = maxInset * CGFloat(i - 1) / CGFloat(bands)
            let outer = peakAlpha * exp(-pow(outerDistance / sigma, 2))
            let inner = peakAlpha * exp(-pow(innerDistance / sigma, 2))
            let alpha = max(0, inner - outer)
            if alpha < 0.0001 { continue }
            let scaleX = max(0.001, (box.width - outerDistance * S * 2) / box.width)
            let scaleY = max(0.001, (box.height - outerDistance * S * 2) / box.height)
            var transform = CGAffineTransform(
                a: scaleX, b: 0, c: 0, d: scaleY,
                tx: box.midX * (1 - scaleX), ty: box.midY * (1 - scaleY))
            guard let innerPath = path.copy(using: &transform) else { continue }
            let ring = CGMutablePath()
            ring.addPath(path)
            ring.addPath(innerPath)
            ctx.addPath(ring)
            ctx.setFillColor(ColorConvert.effectColor(
                r: tint.0, g: tint.1, b: tint.2, alpha: alpha,
                cmyk: options.cmyk, profile: options.printProfile))
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
    }
}
