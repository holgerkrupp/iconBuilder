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
            Section("Color") {
                FormSlider(label: "Opacity", value: Binding(
                    get: { model.layer(g, l)?.opacity.value(for: a) ?? 1 },
                    set: { v in model.withLayer(g, l) { $0.opacity.setValue(v, for: a) } }),
                    range: 0...1, format: "%.0f%%", scale: 100)

                LabeledContent("Blend Mode") {
                    Picker("", selection: Binding(
                        get: { model.layer(g, l)?.blendMode.value(for: a) ?? "normal" },
                        set: { v in model.withLayer(g, l) { $0.blendMode.setValue(v, for: a) } })) {
                        ForEach(["normal", "multiply", "screen", "overlay", "soft-light",
                                 "hard-light", "lighten", "darken"], id: \.self) { m in
                            Text(m.capitalized).tag(m)
                        }
                    }.labelsHidden()
                }

                ColorPicker("Fill", selection: Binding(
                    get: { fillColor },
                    set: { c in setFill(c) }))
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
        }
        .formStyle(.grouped)
    }

    private var fillColor: Color {
        guard let f = model.layer(g, l)?.fill.value(for: model.appearance) else { return .white }
        switch f {
        case .solid(let c), .automaticGradient(let c):
            return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
        case .linearGradient(let stops) where !stops.isEmpty:
            let c = stops[0]
            return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
        default:
            return .white
        }
    }

    private func setFill(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let spec = ColorSpec(space: .srgb, r: ns.redComponent, g: ns.greenComponent,
                             b: ns.blueComponent, a: ns.alphaComponent)
        model.withLayer(g, l) { lyr in
            // Preserve the fill kind: automatic-gradient stays a gradient.
            let current = lyr.fill.value(for: model.appearance)
            switch current {
            case .solid: lyr.fill.setValue(.solid(spec), for: model.appearance)
            default: lyr.fill.setValue(.automaticGradient(spec), for: model.appearance)
            }
        }
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
