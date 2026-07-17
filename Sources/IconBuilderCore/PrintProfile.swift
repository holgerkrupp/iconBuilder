import Foundation
import CoreGraphics
import ColorSync

/// A user-supplied ICC output profile (e.g. ISO Coated v2 300% / FOGRA39)
/// used for profile-accurate CMYK conversion in exports and previews.
public struct PrintProfile: @unchecked Sendable {
    /// The ICC-based CMYK color space. CGColorSpace is immutable.
    public let space: CGColorSpace
    /// Human-readable profile description (from the ICC `desc` tag).
    public let name: String
    /// Where the profile was loaded from (for persistence).
    public let url: URL

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable
        case notAnICCProfile
        case notCMYK(String)

        public var description: String {
            switch self {
            case .unreadable: return "The file could not be read."
            case .notAnICCProfile: return "The file is not a valid ICC profile."
            case .notCMYK(let name): return "“\(name)” is not a CMYK profile. Choose the output profile of your print service (e.g. ISO Coated v2)."
            }
        }
    }

    public static func load(url: URL) throws -> PrintProfile {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable }
        guard let space = CGColorSpace(iccData: data as CFData) else {
            throw LoadError.notAnICCProfile
        }
        var name = url.deletingPathExtension().lastPathComponent
        if let prof = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
           let desc = ColorSyncProfileCopyDescriptionString(prof)?.takeRetainedValue() {
            name = desc as String
        }
        guard space.model == .cmyk else { throw LoadError.notCMYK(name) }
        return PrintProfile(space: space, name: name, url: url)
    }

    /// Rendering intent for the conversion. `.saturation` is the default:
    /// it is designed for vivid flat graphics and keeps icon colors punchy;
    /// colorimetric intents map the wide-gamut screen colors to noticeably
    /// duller tints.
    public var intent: CGColorRenderingIntent = .saturation

    /// Convert any ColorSpec/RGB color into this profile's CMYK space.
    func convert(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat) -> CGColor? {
        let srgb = CGColor(colorSpace: ColorConvert.rgbSpace, components: [r, g, b, 1])
        guard let converted = srgb?.converted(to: space, intent: intent, options: nil) else {
            return nil
        }
        return converted.copy(alpha: alpha)
    }
}

extension PrintProfile: Equatable {
    public static func == (lhs: PrintProfile, rhs: PrintProfile) -> Bool {
        lhs.url == rhs.url && lhs.name == rhs.name
    }
}
