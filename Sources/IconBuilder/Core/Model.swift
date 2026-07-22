import Foundation

/// The four appearance variants an Icon Composer document can specialize for.
/// A value with *no* `appearance` key in the JSON is the base value; it applies
/// to `.light` and acts as the fallback for any appearance without its own entry.
enum Appearance: String, CaseIterable, Sendable, Codable {
    case light
    case dark
    case tinted
    case clear
}

/// A value that may differ per appearance. Built by merging a direct field
/// (e.g. `"glass": true`) with its `*-specializations` array counterpart.
struct Specialized<T: Sendable>: Sendable {
    var base: T?
    var byAppearance: [Appearance: T]

    init(base: T? = nil, byAppearance: [Appearance: T] = [:]) {
        self.base = base
        self.byAppearance = byAppearance
    }

    /// Resolve the effective value for an appearance, falling back to the base.
    func value(for appearance: Appearance) -> T? {
        byAppearance[appearance] ?? base
    }

    /// Write a value for one appearance. Light edits go to the base value
    /// (unless an explicit light specialization exists); other appearances get
    /// their own specialization — mirroring how Icon Composer's inspector
    /// edits the currently shown appearance.
    mutating func setValue(_ newValue: T, for appearance: Appearance) {
        if appearance == .light && byAppearance[.light] == nil {
            base = newValue
        } else {
            byAppearance[appearance] = newValue
        }
    }

    /// Remove an appearance override so it falls back to the base value.
    mutating func removeValue(for appearance: Appearance) {
        if appearance == .light && byAppearance[.light] == nil {
            base = nil
        } else {
            byAppearance.removeValue(forKey: appearance)
        }
    }
}

/// One entry of a `*-specializations` array: `{ "appearance": "dark", "value": … }`.
/// A missing `appearance` marks the base value.
struct AppearanceSpec<T: Codable>: Codable {
    let appearance: Appearance?
    let value: T

    enum CodingKeys: String, CodingKey {
        case appearance
        case value
    }
}

func makeSpecialized<T: Codable & Sendable>(base direct: T?, specs: [AppearanceSpec<T>]?) -> Specialized<T> {
    var b = direct
    var by: [Appearance: T] = [:]
    for s in specs ?? [] {
        if let a = s.appearance { by[a] = s.value } else { b = s.value }
    }
    return Specialized(base: b, byAppearance: by)
}


private func encodeSpecialized<T: Codable & Sendable, K: CodingKey>(
    _ value: Specialized<T>, directKey: K, specializationsKey: K,
    into container: inout KeyedEncodingContainer<K>
) throws {
    try container.encodeIfPresent(value.base, forKey: directKey)
    if !value.byAppearance.isEmpty {
        let specs = Appearance.allCases.compactMap { appearance in
            value.byAppearance[appearance].map { AppearanceSpec(appearance: appearance, value: $0) }
        }
        try container.encode(specs, forKey: specializationsKey)
    }
}

// MARK: - Color

/// A color parsed from strings like `"srgb:0.0,0.99,1.0,1.0"` or
/// `"display-p3:0.27,0.60,0.84,1.0"`.
struct ColorSpec: Sendable, Equatable, Hashable, Codable {
    enum Space: String, Sendable, Hashable, Codable { case srgb, displayP3 }
    var space: Space
    var r: Double, g: Double, b: Double, a: Double

    init(space: Space, r: Double, g: Double, b: Double, a: Double) {
        self.space = space; self.r = r; self.g = g; self.b = b; self.a = a
    }

    init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let spaceName = String(parts[0])
        let space: Space
        switch spaceName {
        case "srgb", "extended-srgb": space = .srgb
        case "display-p3": space = .displayP3
        default: space = .srgb   // tolerate unknown labels as sRGB
        }
        let comps = parts[1].split(separator: ",").compactMap { Double($0) }
        guard comps.count >= 3 else { return nil }
        self.space = space
        self.r = comps[0]; self.g = comps[1]; self.b = comps[2]
        self.a = comps.count >= 4 ? comps[3] : 1.0
    }


    var stringValue: String {
        let prefix = space == .displayP3 ? "display-p3" : "srgb"
        return String(format: "%@:%0.5f,%0.5f,%0.5f,%0.5f", prefix, r, g, b, a)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ColorSpec(string: value) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "Invalid color literal")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
}

// MARK: - Fill

/// A layer/document fill. Icon Composer overrides the SVG's own fill with this.
enum Fill: Sendable, Codable, Equatable {
    case automatic
    case none
    /// A single base color from which Icon Composer synthesizes a soft gradient.
    case automaticGradient(ColorSpec)
    /// An explicit flat color.
    case solid(ColorSpec)
    /// An explicit top→bottom gradient with its own stops.
    case linearGradient([ColorSpec])

    init(from decoder: Decoder) throws {
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
        if let key = DynamicKey(stringValue: "linear-gradient"),
           let strings = try? obj.decode([String].self, forKey: key) {
            let stops = strings.compactMap { ColorSpec(string: $0) }
            if stops.count >= 2 { self = .linearGradient(stops); return }
            if let single = stops.first { self = .solid(single); return }
        }
        self = .automatic
    }


    func encode(to encoder: Encoder) throws {
        switch self {
        case .automatic:
            var c = encoder.singleValueContainer(); try c.encode("automatic")
        case .none:
            var c = encoder.singleValueContainer(); try c.encode("none")
        case .automaticGradient(let color):
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(color.stringValue, forKey: DynamicKey(stringValue: "automatic-gradient")!)
        case .solid(let color):
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(color.stringValue, forKey: DynamicKey(stringValue: "solid")!)
        case .linearGradient(let colors):
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(colors.map(\.stringValue), forKey: DynamicKey(stringValue: "linear-gradient")!)
        }
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - Geometry

struct LayerPosition: Sendable, Codable, Equatable {
    var scale: Double
    /// [x, y] offset in points, Y-up (Apple/PDF convention), origin at canvas center.
    var translation: [Double]

    enum CodingKeys: String, CodingKey {
        case scale
        case translation = "translation-in-points"
    }


    init(scale: Double = 1, translation: [Double] = [0, 0]) {
        self.scale = scale
        self.translation = translation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scale = (try? c.decode(Double.self, forKey: .scale)) ?? 1.0
        self.translation = (try? c.decode([Double].self, forKey: .translation)) ?? [0, 0]
    }

    var tx: Double { translation.count > 0 ? translation[0] : 0 }
    var ty: Double { translation.count > 1 ? translation[1] : 0 }
}

struct Shadow: Sendable, Codable, Equatable {
    var kind: String
    var opacity: Double

    init(kind: String, opacity: Double) {
        self.kind = kind; self.opacity = opacity
    }
}

struct Translucency: Sendable, Codable, Equatable {
    var enabled: Bool
    var value: Double

    init(enabled: Bool, value: Double) {
        self.enabled = enabled; self.value = value
    }
}

/// `blur-material` is unusual in Icon Composer manifests because an explicit
/// JSON null is meaningful and can also appear inside specialization values.
enum BlurMaterial: Sendable, Codable, Equatable {
    case none
    case named(String)

    var name: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .none : .named(try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .none: try c.encodeNil()
        case .named(let name): try c.encode(name)
        }
    }
}

// MARK: - Layer

struct Layer: Sendable, Identifiable {
    let id = UUID()
    var name: String
    var imageName: String
    var position: LayerPosition
    var hidden: Bool
    var fill: Specialized<Fill>
    var opacity: Specialized<Double>
    var glass: Specialized<Bool>
    var blendMode: Specialized<String>

    init(name: String, imageName: String, position: LayerPosition = .identity,
                hidden: Bool = false, fill: Specialized<Fill> = .init(base: .automatic),
                opacity: Specialized<Double> = .init(base: 1),
                glass: Specialized<Bool> = .init(base: false),
                blendMode: Specialized<String> = .init(base: "normal")) {
        self.name = name
        self.imageName = imageName
        self.position = position
        self.hidden = hidden
        self.fill = fill
        self.opacity = opacity
        self.glass = glass
        self.blendMode = blendMode
    }
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

    init(from decoder: Decoder) throws {
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


extension Layer: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(imageName, forKey: .imageName)
        if position != .identity { try c.encode(position, forKey: .position) }
        if hidden { try c.encode(hidden, forKey: .hidden) }
        try encodeSpecialized(fill, directKey: .fill, specializationsKey: .fillSpecializations, into: &c)
        try encodeSpecialized(opacity, directKey: .opacity, specializationsKey: .opacitySpecializations, into: &c)
        try encodeSpecialized(glass, directKey: .glass, specializationsKey: .glassSpecializations, into: &c)
        try encodeSpecialized(blendMode, directKey: .blendMode, specializationsKey: .blendModeSpecializations, into: &c)
    }
}

extension LayerPosition {
    static var identity: LayerPosition {
        LayerPosition()
    }
}

// MARK: - IconGroup

struct IconGroup: Sendable, Identifiable {
    let id = UUID()
    var layers: [Layer]
    var position: LayerPosition
    var hidden: Bool
    var shadow: Shadow?
    var translucency: Specialized<Translucency>
    var blurMaterial: Specialized<BlurMaterial>
    var lighting: Specialized<String>
    var specular: Bool?
    var blendMode: String?
    var refractivity: Refractivity?

    init(layers: [Layer] = [], position: LayerPosition = .identity,
                hidden: Bool = false, shadow: Shadow? = nil,
                translucency: Specialized<Translucency> = .init(),
                blurMaterial: Specialized<BlurMaterial> = .init(),
                lighting: Specialized<String> = .init(base: "individual"),
                specular: Bool? = nil, blendMode: String? = nil,
                refractivity: Refractivity? = nil) {
        self.layers = layers
        self.position = position
        self.hidden = hidden
        self.shadow = shadow
        self.translucency = translucency
        self.blurMaterial = blurMaterial
        self.lighting = lighting
        self.specular = specular
        self.blendMode = blendMode
        self.refractivity = refractivity
    }
}

struct Refractivity: Sendable, Codable, Equatable {
    var enabled: Bool
    var depth: Double
    var strength: Double

    init(enabled: Bool = false, depth: Double = 0, strength: Double = 0.5) {
        self.enabled = enabled
        self.depth = depth
        self.strength = strength
    }

    enum CodingKeys: String, CodingKey { case enabled, depth, strength }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        depth = (try? c.decode(Double.self, forKey: .depth)) ?? 0
        strength = (try? c.decode(Double.self, forKey: .strength)) ?? 0.5
    }
}

extension IconGroup: Decodable {
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
        case refractivity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = (try? c.decode([Layer].self, forKey: .layers)) ?? []
        position = (try? c.decode(LayerPosition.self, forKey: .position)) ?? LayerPosition.identity
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        shadow = try? c.decode(Shadow.self, forKey: .shadow)
        translucency = makeSpecialized(
            base: try? c.decode(Translucency.self, forKey: .translucency),
            specs: try? c.decode([AppearanceSpec<Translucency>].self, forKey: .translucencySpecializations))
        blurMaterial = makeSpecialized(
            base: try? c.decode(BlurMaterial.self, forKey: .blurMaterial),
            specs: try? c.decode([AppearanceSpec<BlurMaterial>].self, forKey: .blurMaterialSpecializations))
        lighting = makeSpecialized(
            base: try? c.decode(String.self, forKey: .lighting),
            specs: try? c.decode([AppearanceSpec<String>].self, forKey: .lightingSpecializations))
        specular = try? c.decode(Bool.self, forKey: .specular)
        blendMode = try? c.decode(String.self, forKey: .blendMode)
        refractivity = try? c.decode(Refractivity.self, forKey: .refractivity)
    }
}


extension IconGroup: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layers, forKey: .layers)
        if position != .identity { try c.encode(position, forKey: .position) }
        if hidden { try c.encode(hidden, forKey: .hidden) }
        try c.encodeIfPresent(shadow, forKey: .shadow)
        try encodeSpecialized(translucency, directKey: .translucency,
                              specializationsKey: .translucencySpecializations, into: &c)
        try encodeSpecialized(blurMaterial, directKey: .blurMaterial,
                              specializationsKey: .blurMaterialSpecializations, into: &c)
        try encodeSpecialized(lighting, directKey: .lighting,
                              specializationsKey: .lightingSpecializations, into: &c)
        try c.encodeIfPresent(specular, forKey: .specular)
        try c.encodeIfPresent(blendMode, forKey: .blendMode)
        try c.encodeIfPresent(refractivity, forKey: .refractivity)
    }
}

// MARK: - Document

struct SupportedPlatforms: Sendable, Equatable {
    var circles: [String]
    var squaresShared: Bool
    var squares: [String]

    init(circles: [String] = [], squaresShared: Bool = true, squares: [String] = []) {
        self.circles = circles
        self.squaresShared = squaresShared
        self.squares = squares
    }
}

struct IconManifest: Sendable, Codable {
    var fill: Fill
    var groups: [IconGroup]
    var supportedPlatforms: SupportedPlatforms?

    init(fill: Fill = .automatic, groups: [IconGroup] = [],
                supportedPlatforms: SupportedPlatforms? = nil) {
        self.fill = fill
        self.groups = groups
        self.supportedPlatforms = supportedPlatforms
    }

    enum CodingKeys: String, CodingKey {
        case fill
        case groups
        case supportedPlatforms = "supported-platforms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fill = (try? c.decode(Fill.self, forKey: .fill)) ?? .automatic
        groups = (try? c.decode([IconGroup].self, forKey: .groups)) ?? []
        supportedPlatforms = try? c.decode(SupportedPlatforms.self, forKey: .supportedPlatforms)
    }
}

extension IconManifest {
    /// Move a runtime layer identity before an index in any group. Manifest
    /// order is topmost-first, so the returned index is also its sidebar row.
    @discardableResult
    mutating func moveLayer(id: UUID, toGroup targetGroup: Int,
                                   before targetIndex: Int) -> (group: Int, index: Int)? {
        guard groups.indices.contains(targetGroup) else { return nil }
        var source: (group: Int, layer: Int)?
        for (g, group) in groups.enumerated() {
            if let l = group.layers.firstIndex(where: { $0.id == id }) {
                source = (g, l); break
            }
        }
        guard let source else { return nil }
        var insertion = max(0, min(targetIndex, groups[targetGroup].layers.count))
        if source.group == targetGroup && source.layer < insertion { insertion -= 1 }
        if source.group == targetGroup && source.layer == insertion {
            return (targetGroup, insertion)
        }
        let moved = groups[source.group].layers.remove(at: source.layer)
        insertion = min(insertion, groups[targetGroup].layers.count)
        groups[targetGroup].layers.insert(moved, at: insertion)
        return (targetGroup, insertion)
    }
}

extension SupportedPlatforms: Decodable {
    enum CodingKeys: String, CodingKey {
        case circles
        case squares
    }
    init(from decoder: Decoder) throws {
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


extension SupportedPlatforms: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(circles, forKey: .circles)
        if squaresShared {
            try c.encode("shared", forKey: .squares)
        } else {
            try c.encode(squares, forKey: .squares)
        }
    }
}
