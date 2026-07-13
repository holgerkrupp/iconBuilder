import Foundation

/// The four appearance variants an Icon Composer document can specialize for.
/// A value with *no* `appearance` key in the JSON is the base value; it applies
/// to `.light` and acts as the fallback for any appearance without its own entry.
public enum Appearance: String, CaseIterable, Sendable, Codable {
    case light
    case dark
    case tinted
    case clear
}

/// A value that may differ per appearance. Built by merging a direct field
/// (e.g. `"glass": true`) with its `*-specializations` array counterpart.
public struct Specialized<T: Sendable>: Sendable {
    public var base: T?
    public var byAppearance: [Appearance: T]

    public init(base: T? = nil, byAppearance: [Appearance: T] = [:]) {
        self.base = base
        self.byAppearance = byAppearance
    }

    /// Resolve the effective value for an appearance, falling back to the base.
    public func value(for appearance: Appearance) -> T? {
        byAppearance[appearance] ?? base
    }
}

/// One entry of a `*-specializations` array: `{ "appearance": "dark", "value": … }`.
/// A missing `appearance` marks the base value.
struct AppearanceSpec<T: Decodable>: Decodable {
    let appearance: Appearance?
    let value: T

    enum CodingKeys: String, CodingKey {
        case appearance
        case value
    }
}

func makeSpecialized<T>(base direct: T?, specs: [AppearanceSpec<T>]?) -> Specialized<T> {
    var b = direct
    var by: [Appearance: T] = [:]
    for s in specs ?? [] {
        if let a = s.appearance { by[a] = s.value } else { b = s.value }
    }
    return Specialized(base: b, byAppearance: by)
}

// MARK: - Color

/// A color parsed from strings like `"srgb:0.0,0.99,1.0,1.0"` or
/// `"display-p3:0.27,0.60,0.84,1.0"`.
public struct ColorSpec: Sendable, Equatable, Hashable {
    public enum Space: String, Sendable, Hashable { case srgb, displayP3 }
    public var space: Space
    public var r: Double, g: Double, b: Double, a: Double

    public init(space: Space, r: Double, g: Double, b: Double, a: Double) {
        self.space = space; self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let spaceName = String(parts[0])
        let space: Space
        switch spaceName {
        case "srgb": space = .srgb
        case "display-p3": space = .displayP3
        default: space = .srgb   // tolerate unknown labels as sRGB
        }
        let comps = parts[1].split(separator: ",").compactMap { Double($0) }
        guard comps.count >= 3 else { return nil }
        self.space = space
        self.r = comps[0]; self.g = comps[1]; self.b = comps[2]
        self.a = comps.count >= 4 ? comps[3] : 1.0
    }
}

// MARK: - Fill

/// A layer/document fill. Icon Composer overrides the SVG's own fill with this.
public enum Fill: Sendable, Decodable {
    case automatic
    case none
    /// A single base color from which Icon Composer synthesizes a soft gradient.
    case automaticGradient(ColorSpec)
    /// An explicit flat color.
    case solid(ColorSpec)

    public init(from decoder: Decoder) throws {
        // Either a bare string ("automatic" / "none" / a color literal)
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "automatic": self = .automatic
            case "none": self = .none
            default:
                if let c = ColorSpec(string: s) { self = .solid(c) } else { self = .automatic }
            }
            return
        }
        // …or an object with a keyed variant.
        let obj = try decoder.container(keyedBy: DynamicKey.self)
        if let key = DynamicKey(stringValue: "automatic-gradient"),
           let s = try? obj.decode(String.self, forKey: key), let c = ColorSpec(string: s) {
            self = .automaticGradient(c); return
        }
        if let key = DynamicKey(stringValue: "solid"),
           let s = try? obj.decode(String.self, forKey: key), let c = ColorSpec(string: s) {
            self = .solid(c); return
        }
        self = .automatic
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - Geometry

public struct LayerPosition: Sendable, Decodable {
    public var scale: Double
    /// [x, y] offset in points, Y-up (Apple/PDF convention), origin at canvas center.
    public var translation: [Double]

    enum CodingKeys: String, CodingKey {
        case scale
        case translation = "translation-in-points"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scale = (try? c.decode(Double.self, forKey: .scale)) ?? 1.0
        self.translation = (try? c.decode([Double].self, forKey: .translation)) ?? [0, 0]
    }

    public var tx: Double { translation.count > 0 ? translation[0] : 0 }
    public var ty: Double { translation.count > 1 ? translation[1] : 0 }
}

public struct Shadow: Sendable, Decodable {
    public var kind: String
    public var opacity: Double
}

public struct Translucency: Sendable, Decodable {
    public var enabled: Bool
    public var value: Double
}

// MARK: - Layer

public struct Layer: Sendable {
    public var name: String
    public var imageName: String
    public var position: LayerPosition
    public var hidden: Bool
    public var fill: Specialized<Fill>
    public var opacity: Specialized<Double>
    public var glass: Specialized<Bool>
    public var blendMode: Specialized<String>
}

extension Layer: Decodable {
    enum CodingKeys: String, CodingKey {
        case name
        case imageName = "image-name"
        case position
        case hidden
        case fill
        case fillSpecializations = "fill-specializations"
        case opacity
        case opacitySpecializations = "opacity-specializations"
        case glass
        case glassSpecializations = "glass-specializations"
        case blendMode = "blend-mode"
        case blendModeSpecializations = "blend-mode-specializations"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        imageName = (try? c.decode(String.self, forKey: .imageName)) ?? ""
        position = (try? c.decode(LayerPosition.self, forKey: .position)) ?? LayerPosition.identity
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        fill = makeSpecialized(
            base: try? c.decode(Fill.self, forKey: .fill),
            specs: try? c.decode([AppearanceSpec<Fill>].self, forKey: .fillSpecializations))
        opacity = makeSpecialized(
            base: try? c.decode(Double.self, forKey: .opacity),
            specs: try? c.decode([AppearanceSpec<Double>].self, forKey: .opacitySpecializations))
        glass = makeSpecialized(
            base: try? c.decode(Bool.self, forKey: .glass),
            specs: try? c.decode([AppearanceSpec<Bool>].self, forKey: .glassSpecializations))
        blendMode = makeSpecialized(
            base: try? c.decode(String.self, forKey: .blendMode),
            specs: try? c.decode([AppearanceSpec<String>].self, forKey: .blendModeSpecializations))
    }
}

extension LayerPosition {
    static var identity: LayerPosition {
        // Decode a trivial value; avoids an extra memberwise init.
        let data = Data("{\"scale\":1,\"translation-in-points\":[0,0]}".utf8)
        return try! JSONDecoder().decode(LayerPosition.self, from: data)
    }
}

// MARK: - Group

public struct Group: Sendable {
    public var layers: [Layer]
    public var position: LayerPosition
    public var hidden: Bool
    public var shadow: Shadow?
    public var translucency: Specialized<Translucency>
    public var blurMaterial: Specialized<String?>
    public var lighting: Specialized<String>
    public var specular: Bool?
    public var blendMode: String?
}

extension Group: Decodable {
    enum CodingKeys: String, CodingKey {
        case layers
        case position
        case hidden
        case shadow
        case translucency
        case translucencySpecializations = "translucency-specializations"
        case blurMaterial = "blur-material"
        case blurMaterialSpecializations = "blur-material-specializations"
        case lighting
        case lightingSpecializations = "lighting-specializations"
        case specular
        case blendMode = "blend-mode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = (try? c.decode([Layer].self, forKey: .layers)) ?? []
        position = (try? c.decode(LayerPosition.self, forKey: .position)) ?? LayerPosition.identity
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        shadow = try? c.decode(Shadow.self, forKey: .shadow)
        translucency = makeSpecialized(
            base: try? c.decode(Translucency.self, forKey: .translucency),
            specs: try? c.decode([AppearanceSpec<Translucency>].self, forKey: .translucencySpecializations))
        // blur-material is nullable; model presence-of-value as an optional String.
        blurMaterial = makeSpecialized(
            base: (try? c.decode(String?.self, forKey: .blurMaterial)) ?? nil,
            specs: try? c.decode([AppearanceSpec<String?>].self, forKey: .blurMaterialSpecializations))
        lighting = makeSpecialized(
            base: try? c.decode(String.self, forKey: .lighting),
            specs: try? c.decode([AppearanceSpec<String>].self, forKey: .lightingSpecializations))
        specular = try? c.decode(Bool.self, forKey: .specular)
        blendMode = try? c.decode(String.self, forKey: .blendMode)
    }
}

// MARK: - Document

public struct SupportedPlatforms: Sendable {
    public var circles: [String]
    public var squaresShared: Bool
    public var squares: [String]
}

public struct IconManifest: Sendable, Decodable {
    public var fill: Fill
    public var groups: [Group]
    public var supportedPlatforms: SupportedPlatforms?

    enum CodingKeys: String, CodingKey {
        case fill
        case groups
        case supportedPlatforms = "supported-platforms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fill = (try? c.decode(Fill.self, forKey: .fill)) ?? .automatic
        groups = (try? c.decode([Group].self, forKey: .groups)) ?? []
        supportedPlatforms = try? c.decode(SupportedPlatforms.self, forKey: .supportedPlatforms)
    }
}

extension SupportedPlatforms: Decodable {
    enum CodingKeys: String, CodingKey {
        case circles
        case squares
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        circles = (try? c.decode([String].self, forKey: .circles)) ?? []
        if let s = try? c.decode(String.self, forKey: .squares), s == "shared" {
            squaresShared = true; squares = []
        } else {
            squaresShared = false
            squares = (try? c.decode([String].self, forKey: .squares)) ?? []
        }
    }
}
