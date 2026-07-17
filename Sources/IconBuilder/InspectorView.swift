import SwiftUI
import IconBuilderCore

/// Contextual inspector, modeled on Icon Composer's: what it shows depends on
/// the sidebar selection (document / group / layer). Values are read and
/// written for the appearance currently shown in the preview.
struct InspectorPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.document != nil {
                applyRecipeBar
                Divider()
            }
            switch model.selection {
            case .document:
                DocumentInspector(model: model)
            case .group(let g):
                if model.group(g) != nil {
                    GroupInspector(model: model, g: g)
                } else {
                    DocumentInspector(model: model)
                }
            case .layer(let g, let l):
                if model.layer(g, l) != nil {
                    LayerInspector(model: model, g: g, l: l)
                } else {
                    DocumentInspector(model: model)
                }
            }
        }
    }

    /// "Apply recipe to selection" — the iOS 26/27 glass defaults, applied to
    /// whatever is selected (document, one group, or one layer).
    private var applyRecipeBar: some View {
        HStack {
            Text(selectionLabel).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("Apply Recipe") {
                ForEach(Recipe.builtins) { r in
                    Button(r.name) { model.applyGlassPreset(r, to: model.selection) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectionLabel: String {
        switch model.selection {
        case .document: return "Document · \(model.appearance.rawValue.capitalized)"
        case .group(let g): return "Group \(g + 1) · \(model.appearance.rawValue.capitalized)"
        case .layer(let g, let l):
            let name = model.layer(g, l)?.name ?? ""
            return "Layer “\(name)” (Group \(g + 1)) · \(model.appearance.rawValue.capitalized)"
        }
    }
}

// MARK: - Document

struct DocumentInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Recipe") {
                Picker("Preset", selection: presetBinding) {
                    ForEach(Recipe.builtins) { r in Text(r.name).tag(r.id) }
                }
                LabeledContent("Mask") {
                    Picker("", selection: $model.recipe.mask) {
                        ForEach(Recipe.MaskShape.allCases, id: \.self) { m in
                            Text(m == .appleSquircle ? "Apple (measured)" : m.rawValue.capitalized).tag(m)
                        }
                    }.labelsHidden()
                }
                FormSlider(label: "Corner", value: $model.recipe.cornerFraction, range: 0...0.5, format: "%.3f")
                if model.recipe.mask == .superellipse {
                    FormSlider(label: "Squircle n", value: $model.recipe.superellipseN, range: 2...8, format: "%.1f")
                }
            }

            Section("Effects") {
                Toggle("Glass specular", isOn: $model.recipe.specularHighlight)
                FormSlider(label: "Specular", value: $model.recipe.specularStrength, range: 0...0.6, format: "%.2f")
                    .disabled(!model.recipe.specularHighlight)
                FormSlider(label: "Layer shadow", value: $model.recipe.layerShadowOpacity, range: 0...0.6, format: "%.2f")
                FormSlider(label: "Edge bezel", value: $model.recipe.edgeBezel, range: 0...0.04, format: "%.3f")
            }

            Section("Render") {
                Toggle("Show effects", isOn: $model.effects)
                Toggle("Background fill", isOn: $model.background)
                Toggle("Clip to mask", isOn: $model.clipToMask)
                Toggle("CMYK preview", isOn: $model.cmykPreview)
                    .help("Preview colors through the print (CMYK) conversion.")
                if model.cmykPreview {
                    LabeledContent("Profile", value: model.printProfile?.name ?? "Built-in")
                        .font(.caption)
                }
            }

            Section("Icon Background") {
                FillEditor(fill: Binding(
                    get: { model.document?.manifest.fill ?? .automatic },
                    set: { value in model.withManifest { $0.fill = value } }))
            }

            Section("Supported Platforms") {
                TextField("Circular", text: platformListBinding(\.circles),
                          prompt: Text("watchOS, visionOS"))
                Toggle("Shared square artwork", isOn: Binding(
                    get: { model.document?.manifest.supportedPlatforms?.squaresShared ?? true },
                    set: { shared in model.withManifest { manifest in
                        var platforms = manifest.supportedPlatforms
                            ?? SupportedPlatforms(circles: [], squaresShared: true, squares: [])
                        platforms.squaresShared = shared
                        manifest.supportedPlatforms = platforms
                    }}))
                if model.document?.manifest.supportedPlatforms?.squaresShared == false {
                    TextField("Square", text: platformListBinding(\.squares),
                              prompt: Text("iOS, macOS"))
                }
            }

            if let doc = model.document {
                Section("Document") {
                    LabeledContent("Groups", value: "\(doc.manifest.groups.count)")
                    LabeledContent("Assets", value: "\(doc.shapes.count)")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.recipe) { model.scheduleRender() }
    }

    private var presetBinding: Binding<String> {
        Binding(get: { model.recipe.id },
                set: { id in
                    if let preset = Recipe.builtins.first(where: { $0.id == id }) {
                        model.recipe = preset
                    }
                })
    }

    private func platformListBinding(_ keyPath: WritableKeyPath<SupportedPlatforms, [String]>) -> Binding<String> {
        Binding(
            get: { model.document?.manifest.supportedPlatforms?[keyPath: keyPath].joined(separator: ", ") ?? "" },
            set: { text in model.withManifest { manifest in
                var platforms = manifest.supportedPlatforms
                    ?? SupportedPlatforms(circles: [], squaresShared: true, squares: [])
                platforms[keyPath: keyPath] = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                manifest.supportedPlatforms = platforms
            }})
    }
}

// MARK: - Group

struct GroupInspector: View {
    @Bindable var model: AppModel
    let g: Int

    var body: some View {
        let a = model.appearance
        Form {
            Section("Liquid Glass") {
                Toggle("Specular", isOn: Binding(
                    get: { model.group(g)?.specular ?? true },
                    set: { v in model.withGroup(g) { $0.specular = v } }))

                let t = model.group(g)?.translucency.value(for: a) ?? Translucency(enabled: false, value: 0.5)
                Toggle("Translucency", isOn: Binding(
                    get: { t.enabled },
                    set: { v in model.withGroup(g) {
                        $0.translucency.setValue(Translucency(enabled: v, value: t.value), for: a)
                    }}))
                FormSlider(label: "Amount", value: Binding(
                    get: { t.value },
                    set: { v in model.withGroup(g) {
                        $0.translucency.setValue(Translucency(enabled: t.enabled, value: v), for: a)
                    }}), range: 0...1, format: "%.0f%%", scale: 100)
                    .disabled(!t.enabled)

                LabeledContent("Shadow") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.shadow?.kind ?? "none" },
                        set: { kind in model.withGroup(g) {
                            let op = $0.shadow?.opacity ?? 0.5
                            $0.shadow = kind == "none" ? nil : Shadow(kind: kind, opacity: op)
                        }})) {
                        Text("None").tag("none")
                        Text("Neutral").tag("neutral")
                        Text("Chromatic").tag("chromatic")
                    }.labelsHidden()
                }
                FormSlider(label: "Shadow opacity", value: Binding(
                    get: { model.group(g)?.shadow?.opacity ?? 0 },
                    set: { v in model.withGroup(g) {
                        $0.shadow = Shadow(kind: $0.shadow?.kind ?? "neutral", opacity: v)
                    }}), range: 0...1, format: "%.0f%%", scale: 100)
                    .disabled(model.group(g)?.shadow == nil)

                LabeledContent("Mode") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.lighting.value(for: a) ?? "individual" },
                        set: { v in model.withGroup(g) { $0.lighting.setValue(v, for: a) } })) {
                        Text("Individual").tag("individual")
                        Text("Combined").tag("combined")
                    }.labelsHidden()
                }

                LabeledContent("Blur material") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.blurMaterial.value(for: a)?.name ?? "none" },
                        set: { value in model.withGroup(g) {
                            $0.blurMaterial.setValue(value == "none" ? .none : .named(value), for: a)
                        }})) {
                        ForEach(["none", "thin", "regular", "thick", "chrome"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }.labelsHidden()
                }

                LabeledContent("Blend mode") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.blendMode ?? "normal" },
                        set: { value in model.withGroup(g) { $0.blendMode = value } })) {
                        ForEach(BlendModeNames.all, id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden()
                }
            }

            Section("Refractivity") {
                let r = model.group(g)?.refractivity ?? Refractivity()
                Toggle("Enabled", isOn: Binding(
                    get: { r.enabled },
                    set: { enabled in model.withGroup(g) {
                        var value = $0.refractivity ?? Refractivity()
                        value.enabled = enabled; $0.refractivity = value
                    }}))
                FormSlider(label: "Depth", value: Binding(
                    get: { r.depth },
                    set: { depth in model.withGroup(g) {
                        var value = $0.refractivity ?? Refractivity()
                        value.depth = depth; $0.refractivity = value
                    }}), range: 0...1, format: "%.2f")
                FormSlider(label: "Strength", value: Binding(
                    get: { r.strength },
                    set: { strength in model.withGroup(g) {
                        var value = $0.refractivity ?? Refractivity()
                        value.strength = strength; $0.refractivity = value
                    }}), range: 0...1, format: "%.2f")
            }

            Section("Composition") {
                Toggle("Visible", isOn: Binding(
                    get: { !(model.group(g)?.hidden ?? false) },
                    set: { v in model.withGroup(g) { $0.hidden = !v } }))
                LayoutControls(
                    position: Binding(
                        get: { model.group(g)?.position ?? .identity },
                        set: { p in model.withGroup(g) { $0.position = p } }))
            }


            if a != .light {
                Section {
                    Button("Remove \(a.rawValue.capitalized) Overrides") {
                        model.withGroup(g) {
                            $0.translucency.removeValue(for: a)
                            $0.blurMaterial.removeValue(for: a)
                            $0.lighting.removeValue(for: a)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layer

struct LayerInspector: View {
    @Bindable var model: AppModel
    let g: Int
    let l: Int

    var body: some View {
        let a = model.appearance
        Form {
            Section("Layer") {
                TextField("Name", text: Binding(
                    get: { model.layer(g, l)?.name ?? "" },
                    set: { value in model.withLayer(g, l) { $0.name = value } }))
                TextField("Asset", text: Binding(
                    get: { model.layer(g, l)?.imageName ?? "" },
                    set: { value in model.withLayer(g, l) { $0.imageName = value } }))
            }

            Section("Color") {
                FormSlider(label: "Opacity", value: Binding(
                    get: { model.layer(g, l)?.opacity.value(for: a) ?? 1 },
                    set: { v in model.withLayer(g, l) { $0.opacity.setValue(v, for: a) } }),
                    range: 0...1, format: "%.0f%%", scale: 100)

                LabeledContent("Blend Mode") {
                    Picker("", selection: Binding(
                        get: { model.layer(g, l)?.blendMode.value(for: a) ?? "normal" },
                        set: { v in model.withLayer(g, l) { $0.blendMode.setValue(v, for: a) } })) {
                        ForEach(BlendModeNames.all, id: \.self) { m in
                            Text(m.capitalized).tag(m)
                        }
                    }.labelsHidden()
                }

                FillEditor(fill: Binding(
                    get: { model.layer(g, l)?.fill.value(for: a) ?? .automatic },
                    set: { value in model.withLayer(g, l) { $0.fill.setValue(value, for: a) } }))
            }

            Section("Liquid Glass") {
                Toggle("Glass", isOn: Binding(
                    get: { model.layer(g, l)?.glass.value(for: a) ?? false },
                    set: { v in model.withLayer(g, l) { $0.glass.setValue(v, for: a) } }))
            }

            Section("Composition") {
                Toggle("Visible", isOn: Binding(
                    get: { !(model.layer(g, l)?.hidden ?? false) },
                    set: { v in model.withLayer(g, l) { $0.hidden = !v } }))
                LayoutControls(
                    position: Binding(
                        get: { model.layer(g, l)?.position ?? .identity },
                        set: { p in model.withLayer(g, l) { $0.position = p } }))
            }


            if let shape = model.selectedShape {
                Section("Shape") {
                    ShapeValueEditor(shape: shape) { model.updateSelectedShape($0) }
                    Toggle("Edit on canvas", isOn: $model.isShapeEditing)
                }
            }

            if a != .light {
                Section {
                    Button("Remove \(a.rawValue.capitalized) Overrides") {
                        model.withLayer(g, l) {
                            $0.fill.removeValue(for: a)
                            $0.opacity.removeValue(for: a)
                            $0.glass.removeValue(for: a)
                            $0.blendMode.removeValue(for: a)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private enum BlendModeNames {
    static let all = ["normal", "multiply", "screen", "overlay", "soft-light",
                      "hard-light", "lighten", "darken", "color-dodge", "color-burn",
                      "difference", "exclusion", "hue", "saturation", "color", "luminosity"]
}

// MARK: - Fill editor

struct FillEditor: View {
    @Binding var fill: Fill

    private enum Kind: String, CaseIterable {
        case automatic = "Automatic"
        case none = "None"
        case automaticGradient = "Automatic Gradient"
        case solid = "Solid"
        case linearGradient = "Linear Gradient"
    }

    var body: some View {
        Picker("Style", selection: kindBinding) {
            ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        switch fill {
        case .automatic, .none:
            EmptyView()
        case .automaticGradient(let color), .solid(let color):
            ColorPicker("Color", selection: colorBinding(color), supportsOpacity: true)
        case .linearGradient(let stops):
            ForEach(stops.indices, id: \.self) { index in
                HStack {
                    ColorPicker("Stop \(index + 1)", selection: gradientStopBinding(index), supportsOpacity: true)
                    if stops.count > 2 {
                        Button { removeStop(index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
            }
            Button("Add Color Stop", systemImage: "plus") { addStop() }
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: {
            switch fill {
            case .automatic: return .automatic
            case .none: return .none
            case .automaticGradient: return .automaticGradient
            case .solid: return .solid
            case .linearGradient: return .linearGradient
            }
        }, set: { kind in
            let color = firstColor ?? IconBuilderCore.ColorSpec(space: .srgb, r: 0.4, g: 0.6, b: 1, a: 1)
            switch kind {
            case .automatic: fill = .automatic
            case .none: fill = .none
            case .automaticGradient: fill = .automaticGradient(color)
            case .solid: fill = .solid(color)
            case .linearGradient:
                fill = .linearGradient([color, IconBuilderCore.ColorSpec(space: color.space, r: color.r * 0.65,
                                                                         g: color.g * 0.65, b: color.b * 0.65, a: color.a)])
            }
        })
    }

    private var firstColor: IconBuilderCore.ColorSpec? {
        switch fill {
        case .automaticGradient(let color), .solid(let color): return color
        case .linearGradient(let stops): return stops.first
        default: return nil
        }
    }

    private func colorBinding(_ current: IconBuilderCore.ColorSpec) -> Binding<Color> {
        Binding(get: { current.swiftUIColor }, set: { color in
            let spec = IconBuilderCore.ColorSpec(color: color, preferredSpace: current.space)
            switch fill {
            case .solid: fill = .solid(spec)
            default: fill = .automaticGradient(spec)
            }
        })
    }

    private func gradientStopBinding(_ index: Int) -> Binding<Color> {
        Binding(get: {
            guard case .linearGradient(let stops) = fill, stops.indices.contains(index) else { return .white }
            return stops[index].swiftUIColor
        }, set: { color in
            guard case .linearGradient(var stops) = fill, stops.indices.contains(index) else { return }
            stops[index] = IconBuilderCore.ColorSpec(color: color, preferredSpace: stops[index].space)
            fill = .linearGradient(stops)
        })
    }

    private func addStop() {
        guard case .linearGradient(var stops) = fill else { return }
        stops.append(stops.last ?? IconBuilderCore.ColorSpec(space: .srgb, r: 1, g: 1, b: 1, a: 1))
        fill = .linearGradient(stops)
    }

    private func removeStop(_ index: Int) {
        guard case .linearGradient(var stops) = fill, stops.count > 2 else { return }
        stops.remove(at: index)
        fill = .linearGradient(stops)
    }
}

private extension IconBuilderCore.ColorSpec {
    var swiftUIColor: Color { Color(red: r, green: g, blue: b, opacity: a) }

    init(color: Color, preferredSpace: IconBuilderCore.ColorSpec.Space) {
        let target: NSColorSpace = preferredSpace == .displayP3 ? .displayP3 : .sRGB
        let ns = NSColor(color).usingColorSpace(target) ?? NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(space: preferredSpace, r: ns.redComponent, g: ns.greenComponent,
                  b: ns.blueComponent, a: ns.alphaComponent)
    }
}

struct ShapeValueEditor: View {
    let shape: EditableShape
    let update: (EditableShape) -> Void

    var body: some View {
        Picker("Type", selection: Binding(
            get: { shape.kind },
            set: { kind in
                guard kind != shape.kind else { return }
                update(EditableShape(kind: kind, frame: shape.bounds,
                                     cornerRadius: shape.cornerRadius,
                                     pathData: kind == .path ? shape.path.svgPathData : nil))
            })) {
                if shape.kind == .path { Text("Path").tag(IconShapeKind.path) }
                ForEach(IconShapeKind.allCases.filter { $0 != .path }) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        LabeledContent("Position") {
            HStack {
                numeric("x", shape.bounds.minX) { setBounds(x: $0) }
                numeric("y", shape.bounds.minY) { setBounds(y: $0) }
            }
        }
        LabeledContent("Size") {
            HStack {
                numeric("w", shape.bounds.width) { setBounds(width: $0) }
                numeric("h", shape.bounds.height) { setBounds(height: $0) }
            }
        }
        if shape.kind == .roundedRectangle {
            FormSlider(label: "Corner radius", value: Binding(
                get: { shape.cornerRadius },
                set: { value in var copy = shape; copy.cornerRadius = value; update(copy) }),
                       range: 0...512, format: "%.0f")
        }
    }

    private func numeric(_ label: String, _ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                      format: .number.precision(.fractionLength(1)))
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func setBounds(x: CGFloat? = nil, y: CGFloat? = nil,
                           width: CGFloat? = nil, height: CGFloat? = nil) {
        let b = shape.bounds
        var copy = shape
        copy.setBounds(CGRect(x: x ?? b.minX, y: y ?? b.minY,
                              width: max(2, width ?? b.width), height: max(2, height ?? b.height)))
        update(copy)
    }
}

// MARK: - Shared controls

/// Layout x/y in points and scale in %, like Icon Composer's Layout row.
struct LayoutControls: View {
    @Binding var position: LayerPosition

    var body: some View {
        LabeledContent("Layout") {
            HStack(spacing: 4) {
                Text("x").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { position.tx },
                                             set: { position.translation = [$0, position.ty] }),
                          format: .number.precision(.fractionLength(1)))
                    .frame(width: 58)
                Text("y").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { position.ty },
                                             set: { position.translation = [position.tx, $0] }),
                          format: .number.precision(.fractionLength(1)))
                    .frame(width: 58)
            }
            .textFieldStyle(.roundedBorder)
        }
        FormSlider(label: "Scale", value: Binding(get: { position.scale },
                                                  set: { position.scale = $0 }),
                   range: 0.1...3, format: "%.0f%%", scale: 100)
    }
}

struct FormSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value * scale))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}
