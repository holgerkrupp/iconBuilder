import SwiftUI

private enum IconBuilderLinks {
    static let privacyPolicy = URL(string: "https://holgerkrupp.de/privacy.txt")!
}

struct IconBuilderDocumentationView: View {
    @State private var selection: IconBuilderDocumentationTopic? = .quickStart

    var body: some View {
        NavigationSplitView {
            List(IconBuilderDocumentationTopic.allCases, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.systemImage)
                    .tag(topic)
            }
            .navigationTitle("Documentation")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            IconBuilderDocumentationArticle(topic: selection ?? .quickStart)
        }
    }
}

private enum IconBuilderDocumentationTopic: String, CaseIterable, Identifiable {
    case quickStart
    case iconBundles
    case workspace
    case appearances
    case screenExport
    case printExport
    case colorManagement
    case automation
    case troubleshooting

    var id: Self { self }

    var title: String {
        switch self {
        case .quickStart: "Quick Start"
        case .iconBundles: "Open & Save"
        case .workspace: "Layers & Shapes"
        case .appearances: "Appearances & Recipes"
        case .screenExport: "PDF & PNG Export"
        case .printExport: "Print-Ready PDF"
        case .colorManagement: "Color Management"
        case .automation: "Shortcuts & Siri"
        case .troubleshooting: "Troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .quickStart: "sparkles"
        case .iconBundles: "app.dashed"
        case .workspace: "square.3.layers.3d"
        case .appearances: "circle.lefthalf.filled"
        case .screenExport: "square.and.arrow.up"
        case .printExport: "printer"
        case .colorManagement: "paintpalette"
        case .automation: "wand.and.stars"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }

    var summary: String {
        switch self {
        case .quickStart: "The shortest path from an Icon Composer project to finished screen or print artwork."
        case .iconBundles: "How IconBuilder reads, imports into, and saves Apple .icon bundles."
        case .workspace: "Organize layers and groups, create shapes, and edit vector artwork."
        case .appearances: "Preview variants and tune platform masks, fills, and Liquid Glass effects."
        case .screenExport: "Create a vector PDF or pixel-sized PNG from the current document and appearance."
        case .printExport: "Prepare physical output with bleed, page boxes, flattening, and a die-cut contour."
        case .colorManagement: "Choose RGB or CMYK output and use a print service’s ICC profile."
        case .automation: "Drive IconBuilder from Shortcuts, Spotlight, and Siri with App Intents."
        case .troubleshooting: "Recover from common open, save, rendering, and export problems."
        }
    }
}

private struct IconBuilderDocumentationArticle: View {
    let topic: IconBuilderDocumentationTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DocumentationHeader(topic: topic)

                switch topic {
                case .quickStart: quickStart
                case .iconBundles: iconBundles
                case .workspace: workspace
                case .appearances: appearances
                case .screenExport: screenExport
                case .printExport: printExport
                case .colorManagement: colorManagement
                case .automation: automation
                case .troubleshooting: troubleshooting
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(topic.title)
    }

    private var quickStart: some View {
        Group {
            DocumentationSection("Open and preview") {
                DocumentationSteps([
                    "Choose File → Import .icon… or drop an Apple .icon bundle into the window. It is copied into your library; the original is left alone.",
                    "Use the segmented control below the canvas to inspect Light, Dark, Tinted, and Clear appearances.",
                    "Select the document, a group, or a layer and adjust its settings in the Inspector."
                ])
            }
            DocumentationSection("Edit and deliver") {
                DocumentationSteps([
                    "Add a vector shape or import SVG artwork, then select it for on-canvas editing.",
                    "Your edits autosave continuously — there is no save step. Use Save Back to Icon Composer (⌘S) when you want the original updated.",
                    "Choose PDF, PNG, or Print-Ready PDF according to the destination’s requirements."
                ])
            }
            DocumentationNote(
                systemImage: "lightbulb.fill",
                text: "You never need to duplicate a bundle by hand: importing already copies it. The original changes only when you explicitly save back to it, which requires IconBuilder Pro."
            )
        }
    }

    private var iconBundles: some View {
        Group {
            DocumentationSection("What opens") {
                DocumentationBullets([
                    "An .icon item is a bundle directory containing icon.json and an Assets folder.",
                    "Referenced SVG assets remain vector. PNG and JPEG artwork can be rendered as image layers.",
                    "Import works from the toolbar, File menu, Finder, recent documents, drag and drop, and a command-line path. Re-importing the same bundle reopens the existing project instead of duplicating it."
                ])
            }
            DocumentationSection("Opening from Finder") {
                Text("IconBuilder appears under Finder's Open With for any .icon bundle. Icon Composer stays the default. To change that, select a .icon bundle in Finder, choose File ▸ Get Info, pick IconBuilder under “Open with:”, then Change All….")
            }
            DocumentationSection("Import SVG into a document") {
                Text("SVG import adds artwork as a new editable layer in the current .icon bundle. It does not replace the open document. Use the Shape menu or the compact shape toolbar to import, or drop one or more .svg files onto the window.")
            }
            DocumentationSection("Saving") {
                DocumentationBullets([
                    "Save writes icon.json and any SVG geometry changed in IconBuilder.",
                    "Untouched source SVG files are left byte-for-byte unchanged.",
                    "Imported and newly created vectors are stored in the bundle’s Assets folder."
                ])
            }
            DocumentationNote(
                systemImage: "externaldrive.badge.exclamationmark",
                text: "Make sure the bundle and its Assets folder are writable. A read-only location can open successfully but cannot be saved."
            )
        }
    }

    private var workspace: some View {
        Group {
            DocumentationSection("Workspace") {
                DocumentationBullets([
                    "Layers and groups on the left control selection, visibility, hierarchy, and front-to-back order.",
                    "The center shows the final rendered appearance or the vector editor for the selected SVG layer.",
                    "The Inspector on the right switches between document, group, and layer controls.",
                    "Use the View menu to show or hide the Layers and Inspector panes."
                ])
            }
            DocumentationSection("Create and arrange") {
                DocumentationBullets([
                    "Add rectangles, ellipses, lines, curves, polygons, stars, arrows, text, paths, and imported SVG artwork.",
                    "Command-click layers to select several, then align, distribute, duplicate, reorder, or delete them together.",
                    "Combine compatible vector layers with Union, Subtract, Intersect, or Exclude Overlap.",
                    "Drag a layer to reorder it or move it into another group."
                ])
            }
            DocumentationSection("Precise vector editing") {
                Text("Selecting a vector layer exposes move and resize handles plus the shared shape and node tools. Inspector fields provide exact geometry, transform, fill, stroke, path adjustment, repeat, and arrangement values. Snapping uses canvas and nearby artwork edges and centers; hold Command while dragging to bypass it temporarily.")
            }
        }
    }

    private var appearances: some View {
        Group {
            DocumentationSection("Appearance selection") {
                Text("The appearance switcher changes both the preview and appearance-specific Inspector controls. Base values remain the fallback when a Light, Dark, Tinted, or Clear override is absent.")
            }
            DocumentationSection("Recipes") {
                DocumentationBullets([
                    "Recipes provide platform-oriented defaults for the outer mask, glass, shadows, rim lighting, and background treatment.",
                    "Applying a recipe updates the currently selected document, group, or layer scope where supported.",
                    "After applying a recipe, every exposed value remains editable."
                ])
            }
            DocumentationSection("Safe review") {
                DocumentationSteps([
                    "Check all four appearances for unintended inherited fills or visibility changes.",
                    "Toggle effects, background, and mask clipping to isolate artwork from presentation effects.",
                    "Use CMYK Preview only as a soft proof; final output still depends on the selected profile and print process."
                ])
            }
        }
    }

    private var screenExport: some View {
        Group {
            DocumentationSection("Vector PDF") {
                DocumentationBullets([
                    "Choose the square point size and whether the PDF should use CMYK or RGB artwork.",
                    "Supported paths and gradients remain vector. Disable cosmetic effects for the cleanest vector separation.",
                    "The export uses the currently selected appearance and current recipe settings."
                ])
            }
            DocumentationSection("PNG") {
                DocumentationBullets([
                    "Choose an exact square pixel size for app, web, or proofing use.",
                    "PNG output is rasterized in Display P3 to match Icon Composer and preserves transparency where the current rendering permits it.",
                    "Use 1024 px when you need a full-size icon proof, then resize downstream only when required."
                ])
            }
            DocumentationNote(
                systemImage: "keyboard",
                text: "Shortcuts: ⇧⌘E exports PDF and ⌥⌘E exports PNG."
            )
        }
    }

    private var printExport: some View {
        Group {
            DocumentationSection("Set up the page") {
                DocumentationBullets([
                    "Target Size is the finished cut size in millimetres; Bleed extends the artwork on every side.",
                    "The exported PDF page includes MediaBox, TrimBox, and BleedBox information.",
                    "CutContour adds a vector spot color named CutContour on its own optional-content layer."
                ])
            }
            DocumentationSection("Vector, flattened, or hybrid") {
                DocumentationBullets([
                    "Leave Flatten Artwork off when the receiving workflow accepts vector artwork and effects.",
                    "Enable flattening and choose a DPI when a print service requires a bitmap-based PDF; the cut line remains vector.",
                    "Choose an Icon Composer PNG as Artwork when the trim area must match Apple’s rendered effects pixel-for-pixel. Vector artwork still supplies the bleed."
                ])
            }
            DocumentationSection("Preflight with the print service") {
                DocumentationSteps([
                    "Confirm finished size, bleed, preferred color mode, profile, flattening, and spot-color naming.",
                    "Export a proof and inspect page dimensions, TrimBox, BleedBox, transparency, and the contour layer.",
                    "Keep a copy without CutContour when the printer creates its own cutting path."
                ])
            }
            DocumentationNote(
                systemImage: "exclamationmark.triangle.fill",
                text: "CutContour is a common production convention, not a guarantee for every RIP. Always follow the receiving service’s specification."
            )
        }
    }

    private var colorManagement: some View {
        Group {
            DocumentationSection("RGB or CMYK") {
                DocumentationBullets([
                    "Screen PNG exports use Display P3; RGB print-ready PDFs use sRGB.",
                    "Use RGB when the destination requests sRGB artwork or performs its own conversion.",
                    "Use CMYK when the print workflow expects separated artwork from IconBuilder.",
                    "Without an imported profile, IconBuilder uses its built-in CMYK conversion."
                ])
            }
            DocumentationSection("Use a print profile") {
                DocumentationSteps([
                    "Ask the print service for the exact ICC output profile used by its workflow.",
                    "Choose Import in the export sheet and select that ICC profile.",
                    "Choose the rendering intent requested by the service; Saturation favors vivid artwork, while Relative Colorimetric preserves in-gamut values more exactly."
                ])
            }
            DocumentationSection("Soft proofing") {
                Text("CMYK Preview estimates the conversion on screen using the selected profile and intent. Displays, inks, media, RIP settings, and printer calibration still affect the physical result, so approve a production proof for color-critical work.")
            }
        }
    }

    private var automation: some View {
        Group {
            DocumentationSection("What you can automate") {
                Text("IconBuilder ships App Intents, so every project in your library is available to the Shortcuts app, Spotlight, and Siri — by name, without the app being open. Actions appear under the “Icons” category.")
            }
            DocumentationSection("Free actions") {
                DocumentationBullets([
                    "Open Icon Project — brings a project on screen in the editor.",
                    "Render Icon Preview — a PNG preview at any appearance, recipe, and size. Watermarked until Pro is unlocked.",
                    "Export Icon as PDF — vector PDF, optionally DeviceCMYK, with an effects toggle.",
                    "Export Icon as PNG — full-resolution Display P3 raster export.",
                    "Export Print-Ready PDF — physical size, bleed, and a CutContour die line.",
                    "Show IconBuilder Pro — opens the one-time purchase."
                ])
            }
            DocumentationSection("Pro actions") {
                DocumentationBullets([
                    "Save Back to Icon Composer — writes the project into the original bundle and returns its path."
                ])
            }
            DocumentationSection("How the Pro check behaves") {
                Text("A Pro action run without the purchase fails with an explanation rather than silently rewriting a `.icon` bundle. Nothing you have already made is affected: the library, preview, PDF/PNG/print exports, autosave, and recovery stay free.")
            }
            DocumentationSection("Editing shortcuts see your latest work") {
                Text("Export actions flush the open editor before rendering, so an automation run while you are working still picks up what is on screen.")
            }
            DocumentationNote(
                systemImage: "info.circle.fill",
                text: "There is no import action. A .icon is a bundle (a folder), and Shortcuts passes files rather than folders — bring projects in through the app, then automate everything after that."
            )
        }
    }

    private var troubleshooting: some View {
        Group {
            DocumentationSection("The bundle will not open") {
                DocumentationBullets([
                    "Confirm you selected the .icon bundle directory rather than icon.json or an individual asset.",
                    "Confirm icon.json exists at the bundle’s top level and contains valid JSON.",
                    "Check that every referenced asset exists in Assets and uses a supported SVG or raster format."
                ])
            }
            DocumentationSection("Artwork is missing or looks different") {
                DocumentationBullets([
                    "Check group and layer visibility in the selected appearance.",
                    "Temporarily disable mask clipping and effects to distinguish source geometry from recipe styling.",
                    "Inspect the layer’s asset name, transform, fill, opacity, and blend mode."
                ])
            }
            DocumentationSection("Save or export fails") {
                DocumentationBullets([
                    "Choose a writable destination with enough free space and permission to create or replace the file.",
                    "For save failures, verify that the open .icon bundle and its Assets folder are writable.",
                    "For a hybrid print export, verify that the chosen artwork file is a readable PNG.",
                    "If an ICC profile causes a failure or unexpected output, remove it and test with the built-in conversion before requesting a replacement profile."
                ])
            }
        }
    }
}

private struct DocumentationHeader: View {
    let topic: IconBuilderDocumentationTopic

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: topic.systemImage)
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(topic.title)
                    .font(.largeTitle.bold())
                Text(topic.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DocumentationSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
            content
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DocumentationBullets: View {
    let items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DocumentationSteps: View {
    let items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.tint, in: Circle())
                        .accessibilityHidden(true)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1): \(item)")
            }
        }
    }
}

private struct DocumentationNote: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .textSelection(.enabled)
    }
}

struct IconBuilderHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("IconBuilder Documentation") {
                openWindow(id: "documentation")
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Getting Started") {
                openWindow(id: "onboarding")
            }

            Divider()

            Link("Privacy Policy", destination: IconBuilderLinks.privacyPolicy)
        }
    }
}

#Preview {
    IconBuilderDocumentationView()
        .frame(width: 900, height: 650)
}
