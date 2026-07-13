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

    /// Naive but standard RGB → CMYK (no ICC). Produces a printable separation.
    public static func cmyk(_ color: ColorSpec) -> CMYK {
        let (r, g, b) = toSRGB(color)
        let k = 1 - max(r, max(g, b))
        if k >= 1 { return CMYK(c: 0, m: 0, y: 0, k: 1, a: CGFloat(color.a)) }
        let c = (1 - r - k) / (1 - k)
        let m = (1 - g - k) / (1 - k)
        let y = (1 - b - k) / (1 - k)
        return CMYK(c: c, m: m, y: y, k: k, a: CGFloat(color.a))
    }

    static let cmykSpace = CGColorSpace(name: CGColorSpace.genericCMYK)!
    static let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A CGColor in the requested working space.
    public static func cgColor(_ color: ColorSpec, cmyk useCMYK: Bool, alpha: CGFloat? = nil) -> CGColor {
        if useCMYK {
            let v = cmyk(color)
            let a = alpha ?? v.a
            return CGColor(colorSpace: cmykSpace, components: [v.c, v.m, v.y, v.k, a])
                ?? CGColor(gray: 0, alpha: a)
        } else {
            let (r, g, b) = toSRGB(color)
            let a = alpha ?? CGFloat(color.a)
            return CGColor(colorSpace: rgbSpace, components: [r, g, b, a]) ?? CGColor(gray: 0, alpha: a)
        }
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
}
