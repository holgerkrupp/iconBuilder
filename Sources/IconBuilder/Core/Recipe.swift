import Foundation
import CoreGraphics

/// An OS "recipe": the mask shape the system clips the icon to, plus the
/// compositing effects (background, layer shadow, specular/glass) it applies.
/// Values are data-driven so they can be tuned in the UI as the specs evolve.
struct Recipe: Sendable, Identifiable, Hashable {
    var id: String
    var name: String

    enum MaskShape: String, Sendable, CaseIterable {
        case appleSquircle  // measured from Icon Composer's exports (exact)
        case superellipse   // parametric approximation
        case circle         // watchOS / clock
        case roundedRect
        case square

        /// How far content should sit inside this mask by default.
        ///
        /// Artwork is authored on a square canvas, so a circular mask cuts the
        /// corners off anything drawn edge to edge — Icon Composer's watchOS
        /// preview shrinks the shared square artwork to sit inside the circle.
        /// The square-family masks follow the canvas, so they need no inset.
        var defaultContentInset: Double {
            switch self {
            case .circle: return 0.11
            case .appleSquircle, .superellipse, .roundedRect, .square: return 0
            }
        }
    }

    var mask: MaskShape
    /// Corner radius as a fraction of the icon size (for roundedRect / how "fat"
    /// the superellipse corner is). iOS app-icon squircle ≈ 0.2237.
    var cornerFraction: Double
    /// Superellipse exponent (higher = squarer). ~5 approximates Apple's squircle.
    var superellipseN: Double
    /// Content is drawn inset from the mask edge by this fraction (safe area).
    var contentInset: Double
    /// Drop-shadow opacity applied under floating layers.
    var layerShadowOpacity: Double
    /// Blur radius (fraction of size) for the layer shadow.
    var layerShadowBlur: Double
    /// Whether to draw a glossy specular highlight sweep (Liquid Glass).
    var specularHighlight: Bool
    /// Strength of the specular highlight, 0…1.
    var specularStrength: Double
    /// A subtle inner bezel/ring around the mask edge (glass rim).
    var edgeBezel: Double
    /// Fallback background when the manifest fill is `automatic`/absent.
    var defaultBackground: ColorSpec
    /// Fallback background for the dark appearance (measured from Icon
    /// Composer 2.0 exports: near-neutral, darker in iOS 27 than iOS 26).
    var defaultDarkBackground: ColorSpec

    init(id: String, name: String, mask: MaskShape, cornerFraction: Double,
                superellipseN: Double, contentInset: Double, layerShadowOpacity: Double,
                layerShadowBlur: Double, specularHighlight: Bool, specularStrength: Double,
                edgeBezel: Double, defaultBackground: ColorSpec,
                defaultDarkBackground: ColorSpec? = nil) {
        self.id = id; self.name = name; self.mask = mask
        self.cornerFraction = cornerFraction; self.superellipseN = superellipseN
        self.contentInset = contentInset; self.layerShadowOpacity = layerShadowOpacity
        self.layerShadowBlur = layerShadowBlur; self.specularHighlight = specularHighlight
        self.specularStrength = specularStrength; self.edgeBezel = edgeBezel
        self.defaultBackground = defaultBackground
        self.defaultDarkBackground = defaultDarkBackground ?? defaultBackground
    }

    // MARK: Axes

    /// A `Recipe` carries two independent things: the *shape* the icon is
    /// clipped to (`mask`, `cornerFraction`, `superellipseN`) and the *lighting*
    /// applied to it (shadow, specular, edge bezel, fallback backgrounds).
    /// A circular icon can use the 27 lighting just as a squircle can, so the
    /// UI picks them separately.
    ///
    /// Returns `preset`'s lighting with this recipe's shape left untouched.
    func applyingLighting(of preset: Recipe) -> Recipe {
        var result = preset
        result.mask = mask
        result.cornerFraction = cornerFraction
        result.superellipseN = superellipseN
        result.contentInset = contentInset
        return result
    }

    // MARK: Built-in lighting presets

    // The 26/27 presets are calibrated against Icon Composer 2.0 reference
    // exports (1024 px): mask geometry measured identical between the two
    // (superellipse ~n 4.2, 45° corner inset ≈ 78 px); they differ only in
    // glass/rim effect strength — iOS 27 has a stronger, cooler edge light
    // and a brighter glass rim.

    /// 26 — Liquid Glass, moderate glass rim and edge light.
    static let iOS26 = Recipe(
        id: "ios26", name: "26",
        mask: .appleSquircle, cornerFraction: 0.2237, superellipseN: 4.2,
        contentInset: 0.0, layerShadowOpacity: 0.28, layerShadowBlur: 0.03,
        specularHighlight: true, specularStrength: 0.18, edgeBezel: 0.010,
        defaultBackground: ColorSpec(space: .srgb, r: 0.16, g: 0.17, b: 0.20, a: 1),
        defaultDarkBackground: ColorSpec(space: .srgb, r: 0.135, g: 0.135, b: 0.133, a: 1))

    /// 27 (Icon Composer 2.0) — stronger glass rim lighting and a crisper,
    /// cooler edge highlight than 26.
    static let iOS27 = Recipe(
        id: "ios27", name: "27",
        mask: .appleSquircle, cornerFraction: 0.2237, superellipseN: 4.2,
        contentInset: 0.0, layerShadowOpacity: 0.32, layerShadowBlur: 0.04,
        specularHighlight: true, specularStrength: 0.30, edgeBezel: 0.014,
        defaultBackground: ColorSpec(space: .srgb, r: 0.13, g: 0.14, b: 0.17, a: 1),
        defaultDarkBackground: ColorSpec(space: .srgb, r: 0.088, g: 0.090, b: 0.090, a: 1))

    /// watchOS — circular mask with its own slightly softer lighting. Not
    /// offered in the inspector, where shape and lighting are chosen
    /// separately (Circle mask + a lighting preset covers it). Kept because
    /// Shortcuts exposes it as a single named recipe.
    static let watchOS = Recipe(
        id: "watchos", name: "watchOS",
        mask: .circle, cornerFraction: 0.5, superellipseN: 2.0,
        contentInset: 0.0, layerShadowOpacity: 0.24, layerShadowBlur: 0.03,
        specularHighlight: true, specularStrength: 0.18, edgeBezel: 0.010,
        defaultBackground: ColorSpec(space: .srgb, r: 0.10, g: 0.11, b: 0.13, a: 1))

    /// Lighting choices offered in the inspector. Shape is picked separately,
    /// so these deliberately exclude mask-defined entries like `watchOS`.
    static let lightingPresets: [Recipe] = [iOS26, iOS27]

    // MARK: Mask geometry

    /// The mask path for an icon drawn in `rect` (canvas coordinates).
    func maskPath(in rect: CGRect) -> CGPath {
        switch mask {
        case .appleSquircle:
            return Recipe.measuredSquirclePath(in: rect)
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


// MARK: - Measured Apple mask contour

extension Recipe {
    /// Apple's exact icon-mask contour, measured from an Icon Composer 2.0
    /// 4096 px export (alpha 0.5 crossing, radial subpixel bisection, 8-fold
    /// symmetry averaged). One quadrant, 1° steps, radii normalized to the
    /// half-size. The parametric superellipse deviates from this by up to
    /// ~5 px at 1024 around 32° — visible against the die-cut line.
    static let measuredQuadrant: [CGPoint] = [
        CGPoint(x: 0.99976, y: 0.00000),
        CGPoint(x: 0.99976, y: 0.01745),
        CGPoint(x: 0.99976, y: 0.03491),
        CGPoint(x: 0.99976, y: 0.05239),
        CGPoint(x: 0.99976, y: 0.06991),
        CGPoint(x: 0.99976, y: 0.08747),
        CGPoint(x: 0.99976, y: 0.10508),
        CGPoint(x: 0.99976, y: 0.12275),
        CGPoint(x: 0.99976, y: 0.14051),
        CGPoint(x: 0.99976, y: 0.15835),
        CGPoint(x: 0.99976, y: 0.17628),
        CGPoint(x: 0.99976, y: 0.19433),
        CGPoint(x: 0.99976, y: 0.21250),
        CGPoint(x: 0.99976, y: 0.23081),
        CGPoint(x: 0.99976, y: 0.24927),
        CGPoint(x: 0.99976, y: 0.26788),
        CGPoint(x: 0.99976, y: 0.28668),
        CGPoint(x: 0.99976, y: 0.30566),
        CGPoint(x: 0.99976, y: 0.32484),
        CGPoint(x: 0.99976, y: 0.34424),
        CGPoint(x: 0.99953, y: 0.36380),
        CGPoint(x: 0.99901, y: 0.38348),
        CGPoint(x: 0.99816, y: 0.40328),
        CGPoint(x: 0.99748, y: 0.42341),
        CGPoint(x: 0.99656, y: 0.44370),
        CGPoint(x: 0.99555, y: 0.46423),
        CGPoint(x: 0.99420, y: 0.48490),
        CGPoint(x: 0.99271, y: 0.50581),
        CGPoint(x: 0.99083, y: 0.52684),
        CGPoint(x: 0.98860, y: 0.54799),
        CGPoint(x: 0.98573, y: 0.56911),
        CGPoint(x: 0.98213, y: 0.59012),
        CGPoint(x: 0.97798, y: 0.61111),
        CGPoint(x: 0.97300, y: 0.63187),
        CGPoint(x: 0.96721, y: 0.65239),
        CGPoint(x: 0.96052, y: 0.67256),
        CGPoint(x: 0.95308, y: 0.69245),
        CGPoint(x: 0.94471, y: 0.71189),
        CGPoint(x: 0.93544, y: 0.73085),
        CGPoint(x: 0.92528, y: 0.74928),
        CGPoint(x: 0.91426, y: 0.76715),
        CGPoint(x: 0.90242, y: 0.78446),
        CGPoint(x: 0.88980, y: 0.80118),
        CGPoint(x: 0.87646, y: 0.81731),
        CGPoint(x: 0.86244, y: 0.83285),
        CGPoint(x: 0.84787, y: 0.84787),
        CGPoint(x: 0.83285, y: 0.86244),
        CGPoint(x: 0.81731, y: 0.87646),
        CGPoint(x: 0.80118, y: 0.88980),
        CGPoint(x: 0.78446, y: 0.90242),
        CGPoint(x: 0.76715, y: 0.91426),
        CGPoint(x: 0.74928, y: 0.92528),
        CGPoint(x: 0.73085, y: 0.93544),
        CGPoint(x: 0.71189, y: 0.94471),
        CGPoint(x: 0.69245, y: 0.95308),
        CGPoint(x: 0.67256, y: 0.96052),
        CGPoint(x: 0.65239, y: 0.96721),
        CGPoint(x: 0.63187, y: 0.97300),
        CGPoint(x: 0.61111, y: 0.97798),
        CGPoint(x: 0.59012, y: 0.98213),
        CGPoint(x: 0.56911, y: 0.98573),
        CGPoint(x: 0.54799, y: 0.98860),
        CGPoint(x: 0.52684, y: 0.99083),
        CGPoint(x: 0.50581, y: 0.99271),
        CGPoint(x: 0.48490, y: 0.99420),
        CGPoint(x: 0.46423, y: 0.99555),
        CGPoint(x: 0.44370, y: 0.99656),
        CGPoint(x: 0.42341, y: 0.99748),
        CGPoint(x: 0.40328, y: 0.99816),
        CGPoint(x: 0.38348, y: 0.99901),
        CGPoint(x: 0.36380, y: 0.99953),
        CGPoint(x: 0.34424, y: 0.99976),
        CGPoint(x: 0.32484, y: 0.99976),
        CGPoint(x: 0.30566, y: 0.99976),
        CGPoint(x: 0.28668, y: 0.99976),
        CGPoint(x: 0.26788, y: 0.99976),
        CGPoint(x: 0.24927, y: 0.99976),
        CGPoint(x: 0.23081, y: 0.99976),
        CGPoint(x: 0.21250, y: 0.99976),
        CGPoint(x: 0.19433, y: 0.99976),
        CGPoint(x: 0.17628, y: 0.99976),
        CGPoint(x: 0.15835, y: 0.99976),
        CGPoint(x: 0.14051, y: 0.99976),
        CGPoint(x: 0.12275, y: 0.99976),
        CGPoint(x: 0.10508, y: 0.99976),
        CGPoint(x: 0.08747, y: 0.99976),
        CGPoint(x: 0.06991, y: 0.99976),
        CGPoint(x: 0.05239, y: 0.99976),
        CGPoint(x: 0.03491, y: 0.99976),
        CGPoint(x: 0.01745, y: 0.99976),
        CGPoint(x: 0.00000, y: 0.99976)
    ]

    /// Full closed path of the measured contour in `rect`, built from the
    /// quadrant table via 8-fold symmetry and a smooth Catmull-Rom fit.
    static func measuredSquirclePath(in rect: CGRect) -> CGPath {
        let q = measuredQuadrant           // 0…90°, index = degrees
        var pts: [CGPoint] = []
        pts.reserveCapacity(360)
        for deg in 0..<360 {
            let quadrant = deg / 90
            let t = deg % 90
            let p: CGPoint
            switch quadrant {
            case 0: p = CGPoint(x: q[t].x, y: q[t].y)
            case 1: p = CGPoint(x: -q[90 - t].x, y: q[90 - t].y)
            case 2: p = CGPoint(x: -q[t].x, y: -q[t].y)
            default: p = CGPoint(x: q[90 - t].x, y: -q[90 - t].y)
            }
            pts.append(p)
        }
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let scaled = pts.map { CGPoint(x: cx + $0.x * rx, y: cy + $0.y * ry) }

        // Closed Catmull-Rom → cubic Bézier.
        let path = CGMutablePath()
        let n = scaled.count
        path.move(to: scaled[0])
        for i in 0..<n {
            let p0 = scaled[(i + n - 1) % n]
            let p1 = scaled[i]
            let p2 = scaled[(i + 1) % n]
            let p3 = scaled[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}
