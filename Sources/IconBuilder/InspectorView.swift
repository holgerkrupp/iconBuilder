import SwiftUI
import IconBuilderCore

struct InspectorPane: View {
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
                            Text(m.rawValue.capitalized).tag(m)
                        }
                    }.labelsHidden()
                }
                slider("Corner", value: $model.recipe.cornerFraction, range: 0...0.5, format: "%.3f")
                if model.recipe.mask == .superellipse {
                    slider("Squircle n", value: $model.recipe.superellipseN, range: 2...8, format: "%.1f")
                }
            }

            Section("Effects") {
                Toggle("Glass specular", isOn: $model.recipe.specularHighlight)
                slider("Specular", value: $model.recipe.specularStrength, range: 0...0.6, format: "%.2f")
                    .disabled(!model.recipe.specularHighlight)
                slider("Layer shadow", value: $model.recipe.layerShadowOpacity, range: 0...0.6, format: "%.2f")
                slider("Edge bezel", value: $model.recipe.edgeBezel, range: 0...0.04, format: "%.3f")
            }

            Section("Render") {
                Toggle("Show effects", isOn: $model.effects)
                Toggle("Background fill", isOn: $model.background)
                Toggle("Clip to mask", isOn: $model.clipToMask)
                Toggle("CMYK preview", isOn: $model.cmykPreview)
                    .help("Preview colors through the print (DeviceCMYK) conversion.")
            }

            if let doc = model.document {
                Section("Document") {
                    LabeledContent("Groups", value: "\(doc.manifest.groups.count)")
                    LabeledContent("Assets", value: "\(doc.shapes.count)")
                    let platforms = doc.manifest.supportedPlatforms
                    if let p = platforms, !p.circles.isEmpty {
                        LabeledContent("Circles", value: p.circles.joined(separator: ", "))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.recipe) { model.scheduleRender() }
    }

    /// Loading a preset replaces the whole editable recipe.
    private var presetBinding: Binding<String> {
        Binding(get: { model.recipe.id },
                set: { id in
                    if let preset = Recipe.builtins.first(where: { $0.id == id }) {
                        model.recipe = preset
                    }
                })
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
