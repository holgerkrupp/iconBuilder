import Foundation
import CoreGraphics

/// Color handling for both on-screen (RGB) preview and print (CMYK) export.
public enum ColorConvert {

    /// CMYK components in 0…1.
    public struct CMYK: Sendable, Equatable {
        public var c: CGFloat, m: CGFloat, y: CGFloat, k: CGFloat, a: CGFloat
    }

    /// Approximate Display-P3 → linear sRGB → sRGB. Good enough for print proofing;
    /// swap in an ICC-managed path later if exact color is required.
    static func toSRGB(_ color: ColorSpec) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch color.space {
        case .srgb:
            return (CGFloat(color.r), CGFloat(color.g), CGFloat(color.b))
        case .displayP3:
            // P3 (gamma) -> linear
            func lin(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let rl = lin(color.r), gl = lin(color.g), bl = lin(color.b)
            // P3 linear -> sRGB linear (Bradford-adapted matrix)
            let r =  1.2249 * rl - 0.2247 * gl + 0.0000 * bl
            let g = -0.0420 * rl + 1.0419 * gl + 0.0000 * bl
            let b = -0.0197 * rl - 0.0786 * gl + 1.0979 * bl
            func gam(_ v: Double) -> Double {
                let c = max(0, min(1, v))
                return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            return (CGFloat(gam(r)), CGFloat(gam(g)), CGFloat(gam(b)))
        }
    }

    /// RGB → CMYK with light GCR (no ICC). The naive full-black-replacement
    /// formula shifts brightness loss into K and under-inks C/M/Y, muting
    /// saturated colors; real print profiles keep midtone "black" in the
    /// chromatic inks. K ramps in only for genuinely dark colors.
    public static func cmyk(_ color: ColorSpec) -> CMYK {
        let (r, g, b) = toSRGB(color)
        let kRaw = 1 - max(r, max(g, b))
        if kRaw >= 1 { return CMYK(c: 0, m: 0, y: 0, k: 1, a: CGFloat(color.a)) }
        // Light GCR: ~30% black replacement in midtones, full for near-black.
        let t = max(0, min(1, (kRaw - 0.55) / 0.35))   // 0 below 0.55, 1 above 0.9
        let smooth = t * t * (3 - 2 * t)
        let k = kRaw * (0.30 + 0.70 * smooth)
        let c = min(1, (1 - r - k) / (1 - k))
        let m = min(1, (1 - g - k) / (1 - k))
        let y = min(1, (1 - b - k) / (1 - k))
        return CMYK(c: max(0, c), m: max(0, m), y: max(0, y), k: k, a: CGFloat(color.a))
    }

    static let cmykSpace = CGColorSpace(name: CGColorSpace.genericCMYK)!
    static let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3Space = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A CGColor in the requested working space. When a `profile` is supplied
    /// with `cmyk`, colors are converted through the ICC profile (perceptual)
    /// instead of the built-in formula.
    public static func cgColor(_ color: ColorSpec, cmyk useCMYK: Bool,
                               alpha: CGFloat? = nil,
                               profile: PrintProfile? = nil) -> CGColor {
        if useCMYK {
            let a = alpha ?? CGFloat(color.a)
            if let profile {
                let (r, g, b) = toSRGB(color)
                if let converted = profile.convert(r: r, g: g, b: b, alpha: a) {
                    return converted
                }
            }
            let v = cmyk(color)
            return CGColor(colorSpace: cmykSpace, components: [v.c, v.m, v.y, v.k, a])
                ?? CGColor(gray: 0, alpha: a)
        } else {
            let a = alpha ?? CGFloat(color.a)
            let sourceSpace = color.space == .displayP3 ? displayP3Space : rgbSpace
            let source = CGColor(colorSpace: sourceSpace,
                                 components: [CGFloat(color.r), CGFloat(color.g), CGFloat(color.b), a])
                ?? CGColor(gray: 0, alpha: a)
            return source.converted(to: displayP3Space, intent: .relativeColorimetric, options: nil)
                ?? source
        }
    }

    /// The working color space for fills/gradients.
    public static func workingSpace(cmyk: Bool, profile: PrintProfile?) -> CGColorSpace {
        cmyk ? (profile?.space ?? cmykSpace) : displayP3Space
    }

    /// Effect colors (highlight whites, shadow darks) specified in RGB,
    /// converted to the working space so PDF output stays in one space.
    public static func effectColor(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat,
                                   cmyk useCMYK: Bool, profile: PrintProfile?) -> CGColor {
        if useCMYK {
            if let profile, let converted = profile.convert(r: r, g: g, b: b, alpha: alpha) {
                return converted
            }
            let v = cmyk(ColorSpec(space: .srgb, r: Double(r), g: Double(g), b: Double(b), a: 1))
            return CGColor(colorSpace: cmykSpace, components: [v.c, v.m, v.y, v.k, alpha])
                ?? CGColor(gray: 0, alpha: alpha)
        }
        let source = CGColor(colorSpace: rgbSpace, components: [r, g, b, alpha])
            ?? CGColor(gray: 0, alpha: alpha)
        return source.converted(to: displayP3Space, intent: .relativeColorimetric, options: nil)
            ?? source
    }

    /// Multiplicative brightness scale (clamped) — a relative falloff that works
    /// well on dark colors where mixing toward white would wash them out.
    public static func scaled(_ color: ColorSpec, by factor: Double) -> ColorSpec {
        var c = color
        c.r = min(1, c.r * factor)
        c.g = min(1, c.g * factor)
        c.b = min(1, c.b * factor)
        return c
    }

    /// Lighten/darken a color by mixing toward white/black — used to synthesize
    /// the soft top-to-bottom gradient Icon Composer generates from a base color.
    public static func adjusted(_ color: ColorSpec, by amount: Double) -> ColorSpec {
        var c = color
        if amount >= 0 {
            c.r += (1 - c.r) * amount
            c.g += (1 - c.g) * amount
            c.b += (1 - c.b) * amount
        } else {
            let f = 1 + amount
            c.r *= f; c.g *= f; c.b *= f
        }
        return c
    }

    /// Additive channel lift used by Icon Composer's automatic material
    /// lighting. Unlike mixing toward white, this keeps saturated hues stable.
    public static func offset(_ color: ColorSpec, by amount: Double) -> ColorSpec {
        var c = color
        c.r = max(0, min(1, c.r + amount))
        c.g = max(0, min(1, c.g + amount))
        c.b = max(0, min(1, c.b + amount))
        return c
    }

    /// Resolve a color to numeric Display P3 components. Glass materials are
    /// composited in the destination gamut, so their tuning belongs here rather
    /// than in the source color's authored space.
    public static func inDisplayP3(_ color: ColorSpec) -> ColorSpec {
        if color.space == .displayP3 { return color }
        let source = CGColor(colorSpace: rgbSpace,
                             components: [CGFloat(color.r), CGFloat(color.g),
                                          CGFloat(color.b), CGFloat(color.a)])
        guard let converted = source?.converted(to: displayP3Space,
                                                intent: .relativeColorimetric,
                                                options: nil),
              let components = converted.components, components.count >= 3 else {
            return color
        }
        return ColorSpec(space: .displayP3,
                         r: Double(components[0]), g: Double(components[1]),
                         b: Double(components[2]), a: color.a)
    }
}
