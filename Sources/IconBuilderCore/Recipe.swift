import Foundation
import CoreGraphics

/// An OS "recipe": the mask shape the system clips the icon to, plus the
/// compositing effects (background, layer shadow, specular/glass) it applies.
/// Values are data-driven so they can be tuned in the UI as the specs evolve.
public struct Recipe: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String

    public enum MaskShape: String, Sendable, CaseIterable {
        case superellipse   // iOS "squircle"
        case circle         // watchOS / clock
        case roundedRect
        case square
    }

    public var mask: MaskShape
    /// Corner radius as a fraction of the icon size (for roundedRect / how "fat"
    /// the superellipse corner is). iOS app-icon squircle ≈ 0.2237.
    public var cornerFraction: Double
    /// Superellipse exponent (higher = squarer). ~5 approximates Apple's squircle.
    public var superellipseN: Double
    /// Content is drawn inset from the mask edge by this fraction (safe area).
    public var contentInset: Double
    /// Drop-shadow opacity applied under floating layers.
    public var layerShadowOpacity: Double
    /// Blur radius (fraction of size) for the layer shadow.
    public var layerShadowBlur: Double
    /// Whether to draw a glossy specular highlight sweep (Liquid Glass).
    public var specularHighlight: Bool
    /// Strength of the specular highlight, 0…1.
    public var specularStrength: Double
    /// A subtle inner bezel/ring around the mask edge (glass rim).
    public var edgeBezel: Double
    /// Fallback background when the manifest fill is `automatic`/absent.
    public var defaultBackground: ColorSpec

    public init(id: String, name: String, mask: MaskShape, cornerFraction: Double,
                superellipseN: Double, contentInset: Double, layerShadowOpacity: Double,
                layerShadowBlur: Double, specularHighlight: Bool, specularStrength: Double,
                edgeBezel: Double, defaultBackground: ColorSpec) {
        self.id = id; self.name = name; self.mask = mask
        self.cornerFraction = cornerFraction; self.superellipseN = superellipseN
        self.contentInset = contentInset; self.layerShadowOpacity = layerShadowOpacity
        self.layerShadowBlur = layerShadowBlur; self.specularHighlight = specularHighlight
        self.specularStrength = specularStrength; self.edgeBezel = edgeBezel
        self.defaultBackground = defaultBackground
    }

    // MARK: Built-in presets

    /// iOS 26 — Liquid Glass squircle, moderate layer shadow, gentle specular sweep.
    public static let iOS26 = Recipe(
        id: "ios26", name: "iOS 26",
        mask: .superellipse, cornerFraction: 0.2237, superellipseN: 5.0,
        contentInset: 0.0, layerShadowOpacity: 0.28, layerShadowBlur: 0.03,
        specularHighlight: true, specularStrength: 0.22, edgeBezel: 0.010,
        defaultBackground: ColorSpec(space: .srgb, r: 0.16, g: 0.17, b: 0.20, a: 1))

    /// iOS 27 — placeholder preset: slightly rounder mask, stronger glass and a
    /// crisper specular. Tune these in the inspector to the shipping spec.
    public static let iOS27 = Recipe(
        id: "ios27", name: "iOS 27",
        mask: .superellipse, cornerFraction: 0.25, superellipseN: 4.4,
        contentInset: 0.0, layerShadowOpacity: 0.32, layerShadowBlur: 0.04,
        specularHighlight: true, specularStrength: 0.30, edgeBezel: 0.014,
        defaultBackground: ColorSpec(space: .srgb, r: 0.13, g: 0.14, b: 0.17, a: 1))

    /// watchOS — circular mask.
    public static let watchOS = Recipe(
        id: "watchos", name: "watchOS (circle)",
        mask: .circle, cornerFraction: 0.5, superellipseN: 2.0,
        contentInset: 0.0, layerShadowOpacity: 0.24, layerShadowBlur: 0.03,
        specularHighlight: true, specularStrength: 0.18, edgeBezel: 0.010,
        defaultBackground: ColorSpec(space: .srgb, r: 0.10, g: 0.11, b: 0.13, a: 1))

    public static let builtins: [Recipe] = [iOS26, iOS27, watchOS]

    // MARK: Mask geometry

    /// The mask path for an icon drawn in `rect` (canvas coordinates).
    public func maskPath(in rect: CGRect) -> CGPath {
        switch mask {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .square:
            return CGPath(rect: rect, transform: nil)
        case .roundedRect:
            let r = min(rect.width, rect.height) * cornerFraction
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .superellipse:
            return Recipe.superellipsePath(in: rect, n: superellipseN, cornerFraction: cornerFraction)
        }
    }

    /// Approximates Apple's squircle: a superellipse blended toward a rounded rect
    /// so the flats stay straight while corners are G2-continuous.
    static func superellipsePath(in rect: CGRect, n: Double, cornerFraction: Double) -> CGPath {
        let steps = 720
        let a = rect.width / 2, b = rect.height / 2
        let cx = rect.midX, cy = rect.midY
        let path = CGMutablePath()
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * Double.pi
            let ct = cos(t), st = sin(t)
            // Superellipse parameterization.
            let x = pow(abs(ct), 2.0 / n) * (ct < 0 ? -1 : 1) * a
            let y = pow(abs(st), 2.0 / n) * (st < 0 ? -1 : 1) * b
            let p = CGPoint(x: cx + x, y: cy + y)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}
