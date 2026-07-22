import SwiftUI
import ShapeEditingUI

/// Contextual inspector, modeled on Icon Composer's: what it shows depends on
/// the sidebar selection (document / group / layer). Values are read and
/// written for the appearance currently shown in the preview.
struct InspectorPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.document == nil {
                InspectorEmptyState()
            } else {
                contextHeader
                Divider()
                switch model.selection {
                case .document:
                    DocumentInspector(model: model)
                case .group(let g):
                    if model.group(g) != nil {
                        GroupSelectionInspector(model: model, g: g)
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
    }

    /// Keeps the editing target visible even after the inspector has scrolled.
    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: scopeIcon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scopeTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(scopeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(appearanceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Active appearance: \(model.appearance.rawValue)")
                    .help("Appearance-specific controls below edit the \(model.appearance.rawValue) appearance.")
            }
            HStack(spacing: 8) {
                Text(scopeExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Menu {
                    ForEach(Recipe.lightingPresets) { recipe in
                        Button(recipe.name) { model.applyGlassPreset(recipe, to: model.selection) }
                    }
                } label: {
                    Label("Apply Recipe", systemImage: "wand.and.sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Apply a glass recipe to \(scopeTitle)")
                .help("Apply Liquid Glass defaults to \(scopeTitle.lowercased()).")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .shapeEditorGlassPanel(cornerRadius: 14)
        .padding(8)
    }

    private var scopeIcon: String {
        switch model.selection {
        case .document: return "doc"
        case .group: return "square.stack.3d.up"
        case .layer: return "square.3.layers.3d"
        }
    }

    private var scopeTitle: String {
        switch model.selection {
        case .document: return "Document"
        case .group(let g): return "Group \(g + 1)"
        case .layer(let g, let l):
            guard let layer = model.layer(g, l) else { return "Layer \(l + 1)" }
            return layer.name.isEmpty ? layer.imageName : layer.name
        }
    }

    private var scopeDetail: String {
        switch model.selection {
        case .document:
            return model.displayName
        case .group(let g):
            let count = model.group(g)?.layers.count ?? 0
            return "\(count) \(count == 1 ? "layer" : "layers")"
        case .layer(let g, _):
            if model.selectedLayerIDs.count > 1 {
                return "Primary layer · \(model.selectedLayerIDs.count) selected"
            }
            return "Layer in Group \(g + 1)"
        }
    }

    private var scopeExplanation: String {
        switch model.selection {
        case .document:
            return "Controls below affect the document or its preview."
        case .group:
            return "Use Group for container settings or Layers to edit all layers in the group."
        case .layer:
            return model.selectedLayerIDs.count > 1
                ? "Properties affect only the primary layer."
                : "Controls below affect the selected layer."
        }
    }

    private var appearanceLabel: String {
        "\(model.appearance.rawValue.capitalized) appearance"
    }
}

private enum GroupInspectorTab: String, CaseIterable, Identifiable {
    case group = "Group"
    case layers = "Layers"

    var id: Self { self }
}

private struct GroupSelectionInspector: View {
    @Bindable var model: AppModel
    let g: Int
    @State private var tab = GroupInspectorTab.group

    var body: some View {
        VStack(spacing: 0) {
            Picker("Group inspector", selection: $tab) {
                ForEach(GroupInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Switch between group-specific settings and controls for all layers in the group.")

            Divider()

            switch tab {
            case .group:
                GroupInspector(model: model, g: g)
            case .layers:
                if model.group(g)?.layers.isEmpty == false {
                    LayerInspector(model: model, g: g, l: 0)
                } else {
                    ContentUnavailableView {
                        Label("No Layers", systemImage: "square.stack.3d.up.slash")
                    } description: {
                        Text("Add a layer to this group to use layer editing tools.")
                    }
                }
            }
        }
    }
}

private struct InspectorEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Selection", systemImage: "sidebar.right")
        } description: {
            Text("Open an icon document to inspect its settings and selected layers.")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InspectorSectionHeader: View {
    let title: String
    let scope: String
    let systemImage: String

    init(_ title: String, scope: String, systemImage: String) {
        self.title = title
        self.scope = scope
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 6)
            Text(scope)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), applies to \(scope)")
    }
}

// MARK: - Document

struct DocumentInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Lighting", selection: presetBinding) {
                    ForEach(Recipe.lightingPresets) { r in Text(r.name).tag(r.id) }
                }
                .help("Choose the lighting and reflection recipe. This does not change the mask shape.")
                LabeledContent("Mask") {
                    Picker("", selection: maskBinding) {
                        ForEach(Recipe.MaskShape.allCases, id: \.self) { m in
                            Text(m == .appleSquircle ? "Apple (measured)" : m.rawValue.capitalized).tag(m)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Document mask shape")
                    .help("Choose the outer mask applied to the icon document.")
                }
                FormSlider(label: "Corner", value: $model.recipe.cornerFraction, range: 0...0.5,
                           format: "%.3f", help: "Adjust the document mask corner size.")
                FormSlider(label: "Content inset", value: $model.recipe.contentInset,
                           range: 0...0.25, format: "%.3f",
                           help: "Shrink the artwork away from the mask edge. Circular masks need this so square artwork isn't clipped.")
                if model.recipe.mask == .superellipse {
                    FormSlider(label: "Squircle n", value: $model.recipe.superellipseN, range: 2...8,
                               format: "%.1f", help: "Adjust the superellipse curvature exponent.")
                }
            } header: {
                InspectorSectionHeader("Recipe", scope: "Document", systemImage: "slider.horizontal.3")
            }

            Section {
                Toggle("Glass specular", isOn: $model.recipe.specularHighlight)
                    .help("Show or hide the document-wide glass highlight.")
                if model.recipe.specularHighlight {
                    FormSlider(label: "Specular", value: $model.recipe.specularStrength,
                               range: 0...0.6, format: "%.2f",
                               help: "Adjust the strength of the document-wide glass highlight.")
                }
                FormSlider(label: "Layer shadow", value: $model.recipe.layerShadowOpacity,
                           range: 0...0.6, format: "%.2f",
                           help: "Adjust the recipe's default layer shadow opacity.")
                FormSlider(label: "Edge bezel", value: $model.recipe.edgeBezel,
                           range: 0...0.04, format: "%.3f",
                           help: "Adjust the highlight around the document mask edge.")
            } header: {
                InspectorSectionHeader("Effects", scope: "Document", systemImage: "sparkles")
            }

            Section {
                Toggle("Show effects", isOn: $model.effects)
                    .help("Include glass, shadow, and bezel effects in the preview.")
                Toggle("Background fill", isOn: $model.background)
                    .help("Show the document background fill in the preview.")
                Toggle("Clip to mask", isOn: $model.clipToMask)
                    .help("Clip the rendered preview to the document mask.")
                Toggle("CMYK preview", isOn: $model.cmykPreview)
                    .help("Preview colors through the print (CMYK) conversion.")
                if model.cmykPreview {
                    LabeledContent("Profile", value: model.printProfile?.name ?? "Built-in")
                        .font(.caption)
                        .accessibilityLabel("CMYK profile: \(model.printProfile?.name ?? "Built-in")")
                }
            } header: {
                InspectorSectionHeader("Render", scope: "Preview only", systemImage: "display")
            }

            Section {
                FillEditor(fill: Binding(
                    get: { model.document?.manifest.fill ?? .automatic },
                    set: { value in model.withManifest { $0.fill = value } }),
                           scopeName: "document background")
            } header: {
                InspectorSectionHeader("Background", scope: "Document", systemImage: "paintpalette")
            }

            Section {
                TextField("Circular", text: platformListBinding(\.circles),
                          prompt: Text("watchOS, visionOS"))
                    .help("Comma-separated platforms that use circular artwork.")
                Toggle("Shared square artwork", isOn: Binding(
                    get: { model.document?.manifest.supportedPlatforms?.squaresShared ?? true },
                    set: { shared in model.withManifest { manifest in
                        var platforms = manifest.supportedPlatforms
                            ?? SupportedPlatforms(circles: [], squaresShared: true, squares: [])
                        platforms.squaresShared = shared
                        manifest.supportedPlatforms = platforms
                    }}))
                    .help("Use the same square artwork for every square icon platform.")
                if model.document?.manifest.supportedPlatforms?.squaresShared == false {
                    TextField("Square", text: platformListBinding(\.squares),
                              prompt: Text("iOS, macOS"))
                        .help("Comma-separated platforms that use square artwork.")
                }
            } header: {
                InspectorSectionHeader("Supported Platforms", scope: "Document", systemImage: "rectangle.3.group")
            }

            if let doc = model.document {
                Section {
                    LabeledContent("Groups", value: "\(doc.manifest.groups.count)")
                    LabeledContent("Assets", value: "\(doc.shapes.count)")
                } header: {
                    InspectorSectionHeader("Info", scope: "Document", systemImage: "info.circle")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.recipe) { model.scheduleRender() }
    }

    /// Changing the mask also moves the content inset to that mask's default,
    /// so switching to Circle pulls the artwork clear of the edge without a
    /// second step. A hand-tuned inset is left alone.
    private var maskBinding: Binding<Recipe.MaskShape> {
        Binding(get: { model.recipe.mask },
                set: { mask in
                    let previous = model.recipe.mask
                    guard mask != previous else { return }
                    if model.recipe.contentInset == previous.defaultContentInset {
                        model.recipe.contentInset = mask.defaultContentInset
                    }
                    model.recipe.mask = mask
                })
    }

    private var presetBinding: Binding<String> {
        Binding(get: {
                    // A document can carry a recipe that isn't a listed lighting
                    // preset (Shortcuts can apply `watchOS`). Those all belong to
                    // the 26 lighting family; show that rather than a blank picker.
                    let id = model.recipe.id
                    return Recipe.lightingPresets.contains { $0.id == id } ? id : Recipe.iOS26.id
                },
                set: { id in
                    if let preset = Recipe.lightingPresets.first(where: { $0.id == id }) {
                        // Shape is a separate choice — keep the document's mask.
                        model.recipe = model.recipe.applyingLighting(of: preset)
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
        let translucency = model.group(g)?.translucency.value(for: a)
            ?? Translucency(enabled: false, value: 0.5)
        let refractivity = model.group(g)?.refractivity ?? Refractivity()
        Form {
            Section {
                Toggle("Translucency", isOn: Binding(
                    get: { translucency.enabled },
                    set: { v in model.withGroup(g) {
                        $0.translucency.setValue(
                            Translucency(enabled: v, value: translucency.value), for: a)
                    }}))
                    .help("Enable translucency for this group in the \(a.rawValue) appearance.")
                if translucency.enabled {
                    FormSlider(label: "Amount", value: Binding(
                        get: { translucency.value },
                        set: { v in model.withGroup(g) {
                            $0.translucency.setValue(
                                Translucency(enabled: translucency.enabled, value: v), for: a)
                        }}), range: 0...1, format: "%.0f%%", scale: 100,
                               help: "Adjust group translucency for the \(a.rawValue) appearance.")
                }

                LabeledContent("Mode") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.lighting.value(for: a) ?? "individual" },
                        set: { v in model.withGroup(g) { $0.lighting.setValue(v, for: a) } })) {
                        Text("Individual").tag("individual")
                        Text("Combined").tag("combined")
                    }
                    .labelsHidden()
                    .accessibilityLabel("Group lighting mode")
                    .help("Choose how layers in this group share lighting in the \(a.rawValue) appearance.")
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
                    }
                    .labelsHidden()
                    .accessibilityLabel("Group blur material")
                    .help("Choose the group's glass blur material for the \(a.rawValue) appearance.")
                }
            } header: {
                InspectorSectionHeader("Appearance", scope: appearanceScope,
                                       systemImage: "circle.lefthalf.filled")
            }

            Section {
                Toggle("Specular", isOn: Binding(
                    get: { model.group(g)?.specular ?? true },
                    set: { v in model.withGroup(g) { $0.specular = v } }))
                    .help("Show or hide the specular highlight for this group in every appearance.")

                LabeledContent("Shadow") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.shadow?.kind ?? "none" },
                        set: { kind in model.withGroup(g) {
                            let opacity = $0.shadow?.opacity ?? 0.5
                            $0.shadow = kind == "none" ? nil : Shadow(kind: kind, opacity: opacity)
                        }})) {
                        Text("None").tag("none")
                        Text("Neutral").tag("neutral")
                        Text("Chromatic").tag("chromatic")
                    }
                    .labelsHidden()
                    .accessibilityLabel("Group shadow style")
                    .help("Choose the shadow applied to this group in every appearance.")
                }
                if model.group(g)?.shadow != nil {
                    FormSlider(label: "Shadow opacity", value: Binding(
                        get: { model.group(g)?.shadow?.opacity ?? 0 },
                        set: { v in model.withGroup(g) {
                            $0.shadow = Shadow(kind: $0.shadow?.kind ?? "neutral", opacity: v)
                        }}), range: 0...1, format: "%.0f%%", scale: 100,
                               help: "Adjust this group's shadow opacity in every appearance.")
                }

                LabeledContent("Blend mode") {
                    Picker("", selection: Binding(
                        get: { model.group(g)?.blendMode ?? "normal" },
                        set: { value in model.withGroup(g) { $0.blendMode = value } })) {
                        ForEach(BlendModeNames.all, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Group blend mode")
                    .help("Choose how this group blends with content below it in every appearance.")
                }
            } header: {
                InspectorSectionHeader("Effects", scope: "All appearances", systemImage: "sparkles")
            }

            Section {
                Toggle("Enabled", isOn: Binding(
                    get: { refractivity.enabled },
                    set: { enabled in model.withGroup(g) {
                        var value = $0.refractivity ?? Refractivity()
                        value.enabled = enabled; $0.refractivity = value
                    }}))
                    .help("Enable refraction for this group in every appearance.")
                if refractivity.enabled {
                    FormSlider(label: "Depth", value: Binding(
                        get: { refractivity.depth },
                        set: { depth in model.withGroup(g) {
                            var value = $0.refractivity ?? Refractivity()
                            value.depth = depth; $0.refractivity = value
                        }}), range: 0...1, format: "%.2f",
                               help: "Adjust the apparent depth of this group's refractive glass.")
                    FormSlider(label: "Strength", value: Binding(
                        get: { refractivity.strength },
                        set: { strength in model.withGroup(g) {
                            var value = $0.refractivity ?? Refractivity()
                            value.strength = strength; $0.refractivity = value
                        }}), range: 0...1, format: "%.2f",
                               help: "Adjust the strength of this group's refraction.")
                }
            } header: {
                InspectorSectionHeader("Refractivity", scope: "All appearances",
                                       systemImage: "drop.degreesign")
            }

            Section {
                Toggle("Visible", isOn: Binding(
                    get: { !(model.group(g)?.hidden ?? false) },
                    set: { v in model.withGroup(g) { $0.hidden = !v } }))
                    .help("Show or hide this group in every appearance.")
                LayoutControls(
                    position: Binding(
                        get: { model.group(g)?.position ?? .identity },
                        set: { p in model.withGroup(g) { $0.position = p } }),
                    scopeName: "group")
            } header: {
                InspectorSectionHeader("Composition", scope: "Group", systemImage: "move.3d")
            }

            if hasAppearanceOverride {
                Section {
                    Button("Remove \(a.rawValue.capitalized) Overrides") {
                        model.withGroup(g) {
                            $0.translucency.removeValue(for: a)
                            $0.blurMaterial.removeValue(for: a)
                            $0.lighting.removeValue(for: a)
                        }
                    }
                    .help("Remove this group's \(a.rawValue) values and use its base appearance values instead.")
                    .accessibilityLabel("Remove \(a.rawValue) appearance overrides from Group \(g + 1)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hasAppearanceOverride: Bool {
        guard let group = model.group(g) else { return false }
        let appearance = model.appearance
        return group.translucency.byAppearance[appearance] != nil
            || group.blurMaterial.byAppearance[appearance] != nil
            || group.lighting.byAppearance[appearance] != nil
    }

    private var appearanceScope: String {
        let name = model.appearance.rawValue.capitalized
        if hasAppearanceOverride { return "\(name) · Has overrides" }
        return model.appearance == .light ? "\(name) · Base" : "\(name) · Inherited"
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
            Section {
                TextField("Name", text: Binding(
                    get: { model.layer(g, l)?.name ?? "" },
                    set: { value in model.withLayer(g, l) { $0.name = value } }))
                    .help("Set the display name of the selected layer.")
                TextField("Asset", text: Binding(
                    get: { model.layer(g, l)?.imageName ?? "" },
                    set: { value in model.withLayer(g, l) { $0.imageName = value } }))
                    .help("Set the asset filename used by the selected layer.")
            } header: {
                InspectorSectionHeader("Identity", scope: primaryScope, systemImage: "tag")
            }

            Section {
                FormSlider(label: "Opacity", value: Binding(
                    get: { model.layer(g, l)?.opacity.value(for: a) ?? 1 },
                    set: { v in model.withLayer(g, l) { $0.opacity.setValue(v, for: a) } }),
                    range: 0...1, format: "%.0f%%", scale: 100,
                    help: "Adjust the selected layer's opacity for the \(a.rawValue) appearance.")

                LabeledContent("Blend Mode") {
                    Picker("", selection: Binding(
                        get: { model.layer(g, l)?.blendMode.value(for: a) ?? "normal" },
                        set: { v in model.withLayer(g, l) { $0.blendMode.setValue(v, for: a) } })) {
                        ForEach(BlendModeNames.all, id: \.self) { m in
                            Text(m.capitalized).tag(m)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Layer blend mode")
                    .help("Choose how the selected layer blends with content below it in the \(a.rawValue) appearance.")
                }

                FillEditor(fill: Binding(
                    get: { model.layer(g, l)?.fill.value(for: a) ?? .automatic },
                    set: { value in model.withLayer(g, l) { $0.fill.setValue(value, for: a) } }),
                           scopeName: "selected layer")
                Toggle("Glass", isOn: Binding(
                    get: { model.layer(g, l)?.glass.value(for: a) ?? false },
                    set: { v in model.withLayer(g, l) { $0.glass.setValue(v, for: a) } }))
                    .help("Enable Liquid Glass for the selected layer in the \(a.rawValue) appearance.")
            } header: {
                InspectorSectionHeader("Appearance", scope: appearanceScope,
                                       systemImage: "circle.lefthalf.filled")
            }

            Section {
                Toggle("Visible", isOn: Binding(
                    get: { !(model.layer(g, l)?.hidden ?? false) },
                    set: { v in model.withLayer(g, l) { $0.hidden = !v } }))
                    .help("Show or hide the selected layer in every appearance.")
                LayoutControls(
                    position: Binding(
                        get: { model.layer(g, l)?.position ?? .identity },
                        set: { p in model.withLayer(g, l) { $0.position = p } }),
                    scopeName: "layer")
            } header: {
                InspectorSectionHeader("Composition", scope: primaryScope, systemImage: "move.3d")
            }

            if model.canResizeSelectedBounds, let bounds = model.selectedCanvasBounds {
                Section {
                    if model.selectedLayerIDs.count > 1 {
                        Text("Selection bounds resize every selected layer together.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Selection bounds resize all \(model.selectedLayerIDs.count) selected layers together.")
                    }
                    SelectionBoundsEditor(bounds: bounds) { model.setSelectedCanvasBounds($0) }
                } header: {
                    InspectorSectionHeader("Selection Bounds", scope: "Selection", systemImage: "selection.pin.in.out")
                }
            }

            if let shape = model.selectedShape {
                Section {
                    if model.selectedLayerIDs.count > 1 {
                        Text("Vector shape values below affect the primary layer only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Vector shape values affect only the primary layer while \(model.selectedLayerIDs.count) layers remain selected.")
                    }
                    ShapeValueEditor(shape: shape,
                                     update: { model.updateSelectedShape($0) },
                                     mutate: { model.mutateSelectedShape($0) },
                                     operation: model.performSelectionOperation)
                } header: {
                    InspectorSectionHeader("Vector Shape", scope: primaryScope, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Section {
                    ShapeGuideControls(settings: $model.canvasSettings)
                } header: {
                    InspectorSectionHeader("Canvas Guides", scope: "Editor", systemImage: "ruler")
                }
            }

            if hasAppearanceOverride {
                Section {
                    Button("Remove \(a.rawValue.capitalized) Overrides") {
                        model.withLayer(g, l) {
                            $0.fill.removeValue(for: a)
                            $0.opacity.removeValue(for: a)
                            $0.glass.removeValue(for: a)
                            $0.blendMode.removeValue(for: a)
                        }
                    }
                    .help("Remove this layer's \(a.rawValue) values and use its base appearance values instead.")
                    .accessibilityLabel("Remove \(a.rawValue) appearance overrides from the selected layer")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var primaryScope: String {
        model.selectedLayerIDs.count > 1 ? "Primary layer" : "Layer"
    }

    private var hasAppearanceOverride: Bool {
        guard let layer = model.layer(g, l) else { return false }
        let appearance = model.appearance
        return layer.fill.byAppearance[appearance] != nil
            || layer.opacity.byAppearance[appearance] != nil
            || layer.glass.byAppearance[appearance] != nil
            || layer.blendMode.byAppearance[appearance] != nil
    }

    private var appearanceScope: String {
        let name = model.appearance.rawValue.capitalized
        if hasAppearanceOverride { return "\(name) · Has overrides" }
        return model.appearance == .light ? "\(name) · Base" : "\(name) · Inherited"
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
    var scopeName = "fill"

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
        .accessibilityLabel("\(scopeName.capitalized) fill style")
        .help("Choose the fill style for the \(scopeName).")
        switch fill {
        case .automatic, .none:
            EmptyView()
        case .automaticGradient(let color), .solid(let color):
            ColorPicker("Color", selection: colorBinding(color), supportsOpacity: true)
                .accessibilityLabel("\(scopeName.capitalized) fill color")
                .help("Choose the fill color for the \(scopeName).")
        case .linearGradient(let stops):
            ForEach(stops.indices, id: \.self) { index in
                HStack {
                    ColorPicker("Stop \(index + 1)", selection: gradientStopBinding(index), supportsOpacity: true)
                        .accessibilityLabel("Gradient stop \(index + 1) color")
                        .help("Choose the color for gradient stop \(index + 1).")
                    if stops.count > 2 {
                        Button { removeStop(index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove gradient stop \(index + 1)")
                            .help("Remove gradient stop \(index + 1).")
                    }
                }
            }
            Button("Add Color Stop", systemImage: "plus") { addStop() }
                .help("Add another color to the linear gradient.")
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
            let color = firstColor ?? ColorSpec(space: .srgb, r: 0.4, g: 0.6, b: 1, a: 1)
            switch kind {
            case .automatic: fill = .automatic
            case .none: fill = .none
            case .automaticGradient: fill = .automaticGradient(color)
            case .solid: fill = .solid(color)
            case .linearGradient:
                fill = .linearGradient([color, ColorSpec(space: color.space, r: color.r * 0.65,
                                                                         g: color.g * 0.65, b: color.b * 0.65, a: color.a)])
            }
        })
    }

    private var firstColor: ColorSpec? {
        switch fill {
        case .automaticGradient(let color), .solid(let color): return color
        case .linearGradient(let stops): return stops.first
        default: return nil
        }
    }

    private func colorBinding(_ current: ColorSpec) -> Binding<Color> {
        Binding(get: { current.swiftUIColor }, set: { color in
            let spec = ColorSpec(color: color, preferredSpace: current.space)
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
            stops[index] = ColorSpec(color: color, preferredSpace: stops[index].space)
            fill = .linearGradient(stops)
        })
    }

    private func addStop() {
        guard case .linearGradient(var stops) = fill else { return }
        stops.append(stops.last ?? ColorSpec(space: .srgb, r: 1, g: 1, b: 1, a: 1))
        fill = .linearGradient(stops)
    }

    private func removeStop(_ index: Int) {
        guard case .linearGradient(var stops) = fill, stops.count > 2 else { return }
        stops.remove(at: index)
        fill = .linearGradient(stops)
    }
}

private extension ColorSpec {
    var swiftUIColor: Color { Color(red: r, green: g, blue: b, opacity: a) }

    init(color: Color, preferredSpace: ColorSpec.Space) {
        let target: NSColorSpace = preferredSpace == .displayP3 ? .displayP3 : .sRGB
        let ns = NSColor(color).usingColorSpace(target) ?? NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(space: preferredSpace, r: ns.redComponent, g: ns.greenComponent,
                  b: ns.blueComponent, a: ns.alphaComponent)
    }
}

struct ShapeValueEditor: View {
    let shape: EditableShape
    let update: (EditableShape) -> Void
    let mutate: ((inout EditableShape) -> Void) -> Void
    let operation: (ShapeSelectionOperation) -> Void

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
        .help("Change the vector shape type of the selected layer.")
        if shape.kind == .text {
            ShapeTextControls(text: shape.text, fontName: shape.fontName) { text, fontName in
                mutate {
                    $0.text = text
                    $0.fontName = fontName
                }
            }
            ShapeTextLayoutControls(value: shape.textLayout) { layout in
                mutate { $0.textLayout = layout }
            } attachToSelectedPath: {
                operation(.attachTextToPath)
            } convertToOutlines: {
                operation(.convertTextToOutlines)
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
                set: { value in mutate { $0.cornerRadius = value } }),
                       range: 0...512, format: "%.0f")
        }
        DisclosureGroup("Stroke") {
            if let reason = shape.strokeModeUnavailableReason {
                footer(reason)
            } else if shape.canToggleFilled {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Filled", isOn: Binding(
                        get: { shape.isFilled },
                        set: { value in mutate { $0.isFilled = value } }))
                    footer(strokeFillFooter)
                }
            } else {
                footer("Lines and curves always render as strokes, so Filled does not apply to this shape type.")
            }
            ShapeStrokeControls(
                value: shape.strokeStyle,
                update: { style in
                    mutate { $0.strokeStyle = style }
                },
                outline: {
                    operation(.outlineStroke)
                },
                isStrokeActive: shape.usesStrokeRendering,
                supportsAlignment: shape.supportsStrokeAlignment,
                supportsMarkers: shape.supportsStrokeMarkers,
                defaultWidth: shape.strokeDefaultWidth,
                modeExplanation: strokeModeExplanation
            )
            if shape.canToggleFilled && shape.isFilled && shape.hasExplicitStrokeStyle {
                footer("Saved stroke settings are currently inactive because the layer is rendering as a fill. Turn Filled off to reuse them.")
            }
        }
        .help("Edit fill and stroke settings for the selected vector shape.")
        DisclosureGroup("Path Effects") {
            ShapePathEffectControls(
                applyOffset: { operation(.offset($0)) },
                roundCorners: { operation(.roundCorners($0)) },
                simplify: { operation(.simplify($0)) })
        }
        .help("Apply non-destructive path adjustments to the selected vector shape.")
        if let mask = shape.mask {
            DisclosureGroup("Mask") {
                ShapeMaskControls(value: mask) { value in
                    mutate { $0.mask = value }
                } release: {
                    operation(.releaseMask)
                }
            }
        }
        DisclosureGroup("Arrange") {
            ShapeArrangementControls(operation: operation)
        }
        .help("Align or distribute the selected layers.")
        DisclosureGroup("Repeat and Symmetry") {
            ShapeRepeatControls { operation(.repeatTransform($0)) }
            HStack {
                Button("Mirror H") { operation(.mirror(.horizontal)) }
                    .help("Mirror the selected vector shape horizontally.")
                Button("Mirror V") { operation(.mirror(.vertical)) }
                    .help("Mirror the selected vector shape vertically.")
            }
        }
        .help("Repeat or mirror the selected vector shape.")
        Divider()
        ShapeTransformationControls(value: shape.transformation) { transformation in
            mutate { $0.transformation = transformation }
        }
    }

    private func numeric(_ label: String, _ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                      format: .number.precision(.fractionLength(1)))
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(numericAccessibilityLabel(label))
                .help("Set the shape's \(numericAccessibilityLabel(label).lowercased()).")
        }
    }

    private func numericAccessibilityLabel(_ label: String) -> String {
        switch label {
        case "x": return "X position"
        case "y": return "Y position"
        case "w": return "Width"
        case "h": return "Height"
        default: return label
        }
    }

    private var strokeModeExplanation: String {
        if let reason = shape.strokeModeUnavailableReason {
            return reason
        }
        if shape.usesStrokeRendering {
            if shape.kind == .line || shape.kind == .curve {
                return "This layer is rendering as a stroke. The controls below change the visible stroke width, dash pattern, and endpoint styling."
            }
            return "This layer is currently rendering as a stroke outline. Width, dashes, alignment, and Outline Stroke all affect the visible geometry."
        }
        return "This layer is currently rendering as a fill. Turn Filled off to switch into stroke-outline mode and enable the controls below."
    }

    private var strokeFillFooter: String {
        "Filled uses the path area as-is. Turn this off to render the same path as an outline stroke instead. Icon Builder currently renders a vector layer as either a fill or a stroke outline, not both at once."
    }

    @ViewBuilder private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func setBounds(x: CGFloat? = nil, y: CGFloat? = nil,
                           width: CGFloat? = nil, height: CGFloat? = nil) {
        mutate {
            let b = $0.bounds
            $0.setBounds(CGRect(x: x ?? b.minX, y: y ?? b.minY,
                                width: max(2, width ?? b.width), height: max(2, height ?? b.height)))
        }
    }
}

struct SelectionBoundsEditor: View {
    let bounds: CGRect
    let setBounds: (CGRect) -> Void

    var body: some View {
        LabeledContent("Position") {
            HStack {
                numeric("x", bounds.minX) { apply(x: $0) }
                numeric("y", bounds.minY) { apply(y: $0) }
            }
        }
        LabeledContent("Size") {
            HStack {
                numeric("w", bounds.width) { apply(width: $0) }
                numeric("h", bounds.height) { apply(height: $0) }
            }
        }
    }

    private func numeric(_ label: String, _ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                      format: .number.precision(.fractionLength(1)))
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(numericAccessibilityLabel(label))
                .help("Set the selection's \(numericAccessibilityLabel(label).lowercased()).")
        }
    }

    private func numericAccessibilityLabel(_ label: String) -> String {
        switch label {
        case "x": return "Selection X position"
        case "y": return "Selection Y position"
        case "w": return "Selection width"
        case "h": return "Selection height"
        default: return label
        }
    }

    private func apply(x: CGFloat? = nil, y: CGFloat? = nil,
                       width: CGFloat? = nil, height: CGFloat? = nil) {
        let target = CGRect(x: x ?? bounds.minX, y: y ?? bounds.minY,
                            width: max(2, width ?? bounds.width),
                            height: max(2, height ?? bounds.height))
        setBounds(target)
    }
}

// MARK: - Shared controls

/// Layout x/y in points and scale in %, like Icon Composer's Layout row.
struct LayoutControls: View {
    @Binding var position: LayerPosition
    var scopeName = "item"

    var body: some View {
        LabeledContent("Layout") {
            HStack(spacing: 4) {
                Text("x").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("", value: Binding(get: { position.tx },
                                             set: { position.translation = [$0, position.ty] }),
                          format: .number.precision(.fractionLength(1)))
                    .frame(width: 58)
                    .accessibilityLabel("\(scopeName.capitalized) X position")
                    .help("Set the horizontal position of the \(scopeName).")
                Text("y").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("", value: Binding(get: { position.ty },
                                             set: { position.translation = [position.tx, $0] }),
                          format: .number.precision(.fractionLength(1)))
                    .frame(width: 58)
                    .accessibilityLabel("\(scopeName.capitalized) Y position")
                    .help("Set the vertical position of the \(scopeName).")
            }
            .textFieldStyle(.roundedBorder)
        }
        FormSlider(label: "Scale", value: Binding(get: { position.scale },
                                                  set: { position.scale = $0 }),
                   range: 0.1...3, format: "%.0f%%", scale: 100,
                   help: "Scale the \(scopeName) uniformly.")
    }
}

struct FormSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).accessibilityHidden(true)
                Spacer()
                Text(String(format: format, value * scale))
                    .foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityHidden(true)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(label)
                .accessibilityValue(String(format: format, value * scale))
                .help(help ?? "Adjust \(label.lowercased()).")
        }
    }
}
