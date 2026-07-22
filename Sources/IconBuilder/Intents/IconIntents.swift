import AppIntents
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Free
//
// Nothing here touches ProGate. Browsing the library, opening a project and
// looking at a watermarked preview stay free for the same reason autosave does:
// they are how you get at work you have already done.

/// Brings a project on screen in the editor.
struct OpenIconProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Icon Project"
    static let description = IntentDescription(
        "Opens a project from the IconBuilder library in the editor.",
        categoryName: "Icons")

    static let openAppWhenRun = true

    @Parameter(title: "Project")
    var project: IconProjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let resolved = try project.resolveProject()
        IconNavigator.shared.requestOpen(projectID: resolved.id)
        return .result()
    }
}

/// A rendered preview of the icon. Free on purpose: it shows prospective buyers
/// exactly what export produces, watermarked until Pro is unlocked.
struct RenderIconPreviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Render Icon Preview"
    static let description = IntentDescription(
        "Renders a project as a PNG preview. Previews are watermarked until IconBuilder Pro is unlocked.",
        categoryName: "Icons",
        searchKeywords: ["preview", "render", "png"])

    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: IconProjectEntity

    @Parameter(title: "Appearance", default: .light)
    var appearance: Appearance

    @Parameter(title: "Recipe", default: .iOS26)
    var recipe: IconRecipeChoice

    @Parameter(title: "Size",
               description: "Width and height of the preview in pixels.",
               default: 512,
               inclusiveRange: (16, 2048))
    var size: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Render a preview of \(\.$project)") {
            \.$appearance
            \.$recipe
            \.$size
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let resolved = try project.resolveProject()
        let doc = try IntentRenderSupport.loadDocument(for: resolved)
        let options = RenderOptions(appearance: appearance, recipe: recipe.recipe)

        guard var image = Exporters.rasterize(doc, pixelSize: size, options: options) else {
            throw IconIntentError.renderFailed(resolved.name)
        }
        if !StoreManager.shared.isUnlocked,
           let stamped = IntentRenderSupport.watermarked(image) {
            image = stamped
        }
        guard let data = IntentRenderSupport.pngData(image) else {
            throw IconIntentError.renderFailed(resolved.name)
        }
        return .result(value: IntentFile(data: data,
                                         filename: "\(resolved.name)-preview.png",
                                         type: .png))
    }
}

/// Opens the app on the purchase sheet — what the paid intents point users at.
struct ShowIconBuilderProIntent: AppIntent {
    static let title: LocalizedStringResource = "Show IconBuilder Pro"
    static let description = IntentDescription(
        "Opens IconBuilder and shows the one-time Pro purchase that unlocks saving `.icon` files.",
        categoryName: "Icons")

    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IconNavigator.shared.requestPaywall()
        return .result()
    }
}

// MARK: - Exports

/// Vector PDF export, the workhorse for print and design handoff.
struct ExportIconPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Icon as PDF"
    static let description = IntentDescription(
        "Exports a project as a vector PDF, optionally in DeviceCMYK for print.",
        categoryName: "Icons",
        searchKeywords: ["export", "pdf", "vector", "cmyk"])

    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: IconProjectEntity

    @Parameter(title: "Size (points)", default: 1024, inclusiveRange: (16, 4096))
    var pointSize: Int

    @Parameter(title: "Appearance", default: .light)
    var appearance: Appearance

    @Parameter(title: "Recipe", default: .iOS26)
    var recipe: IconRecipeChoice

    @Parameter(title: "CMYK Color",
               description: "DeviceCMYK for prepress. Off exports sRGB.",
               default: true)
    var cmyk: Bool

    @Parameter(title: "Include Cosmetic Effects",
               description: "Off keeps the file a clean, fully-vector separation.",
               default: false)
    var effects: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$project) as a PDF") {
            \.$pointSize
            \.$appearance
            \.$recipe
            \.$cmyk
            \.$effects
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let resolved = try project.resolveProject()
        let doc = try IntentRenderSupport.loadDocument(for: resolved)
        let options = RenderOptions(appearance: appearance, recipe: recipe.recipe,
                                    cmyk: cmyk, effects: effects)
        guard let data = Exporters.pdfData(doc, pointSize: CGFloat(pointSize), options: options) else {
            throw IconIntentError.exportFailed(resolved.name, "The PDF could not be generated.")
        }
        return .result(value: IntentFile(data: data,
                                         filename: "\(resolved.name).pdf",
                                         type: .pdf))
    }
}

/// Full-resolution, unwatermarked raster export.
struct ExportIconPNGIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Icon as PNG"
    static let description = IntentDescription(
        "Exports a project as a full-resolution Display P3 PNG, with no watermark.",
        categoryName: "Icons",
        searchKeywords: ["export", "png", "raster"])

    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: IconProjectEntity

    @Parameter(title: "Size (pixels)", default: 1024, inclusiveRange: (16, 4096))
    var pixelSize: Int

    @Parameter(title: "Appearance", default: .light)
    var appearance: Appearance

    @Parameter(title: "Recipe", default: .iOS26)
    var recipe: IconRecipeChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$project) as a PNG") {
            \.$pixelSize
            \.$appearance
            \.$recipe
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let resolved = try project.resolveProject()
        let doc = try IntentRenderSupport.loadDocument(for: resolved)
        let options = RenderOptions(appearance: appearance, recipe: recipe.recipe)
        guard let image = Exporters.rasterize(doc, pixelSize: pixelSize, options: options),
              let data = IntentRenderSupport.pngData(image) else {
            throw IconIntentError.exportFailed(resolved.name, "The PNG could not be rendered.")
        }
        return .result(value: IntentFile(data: data,
                                         filename: "\(resolved.name)-\(pixelSize).png",
                                         type: .png))
    }
}

/// Print-ready PDF with bleed and a CutContour die line.
struct ExportPrintReadyPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Print-Ready PDF"
    static let description = IntentDescription(
        "Exports a project as a print-ready PDF with bleed and an optional CutContour die line.",
        categoryName: "Icons",
        searchKeywords: ["print", "bleed", "cutcontour", "die", "cmyk"])

    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: IconProjectEntity

    @Parameter(title: "Icon Size (mm)", default: 50, inclusiveRange: (10, 500))
    var sizeMM: Double

    @Parameter(title: "Bleed (mm)", default: 3, inclusiveRange: (0, 20))
    var bleedMM: Double

    @Parameter(title: "Appearance", default: .light)
    var appearance: Appearance

    @Parameter(title: "Recipe", default: .iOS26)
    var recipe: IconRecipeChoice

    @Parameter(title: "Cut Line",
               description: "A CutContour spot-colour die line on its own layer.",
               default: true)
    var cutLine: Bool

    @Parameter(title: "RGB Instead of CMYK",
               description: "Let the print service convert with their own profiles.",
               default: false)
    var rgb: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$project) as a print-ready PDF") {
            \.$sizeMM
            \.$bleedMM
            \.$appearance
            \.$recipe
            \.$cutLine
            \.$rgb
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let resolved = try project.resolveProject()
        let doc = try IntentRenderSupport.loadDocument(for: resolved)
        let options = RenderOptions(appearance: appearance, recipe: recipe.recipe,
                                    cmyk: !rgb, effects: true)
        let print = Exporters.PrintOptions(targetSizeMM: sizeMM, bleedMM: bleedMM,
                                           dpi: 300, flatten: false,
                                           cutLine: cutLine, rgb: rgb,
                                           artworkPNGURL: nil)
        // Exporters writes print PDFs to a URL, so stage it in a temporary file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try Exporters.exportPrintPDF(doc, to: tmp, print: print, options: options)
        } catch {
            throw IconIntentError.exportFailed(resolved.name, String(describing: error))
        }
        let data = try Data(contentsOf: tmp)
        return .result(value: IntentFile(
            data: data,
            filename: "\(resolved.name)-print-\(Int(sizeMM))mm\(rgb ? "-rgb" : "").pdf",
            type: .pdf))
    }
}

// MARK: - Pro

/// Writes the working copy back over the original bundle it was imported from.
struct SaveBackToIconComposerIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Back to Icon Composer"
    static let description = IntentDescription(
        "Writes a project's edits back into the original .icon bundle it was imported from. Requires IconBuilder Pro.",
        categoryName: "Icons",
        searchKeywords: ["save", "icon composer", "write back"])

    static let openAppWhenRun = false

    @Parameter(title: "Project")
    var project: IconProjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$project) back to Icon Composer")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ProGate.requireUnlocked()
        let resolved = try project.resolveProject()
        // Flush before copying, so the write-back includes on-screen edits.
        _ = try IntentRenderSupport.loadDocument(for: resolved)

        guard let origin = ProjectLibrary.shared.resolveOrigin(for: resolved) else {
            throw IconIntentError.noOrigin(resolved.name)
        }
        defer { if origin.secured { origin.url.stopAccessingSecurityScopedResource() } }
        do {
            try ProjectLibrary.shared.copyWorkingCopy(of: resolved, to: origin.url)
        } catch {
            throw IconIntentError.exportFailed(resolved.name, String(describing: error))
        }
        return .result(value: origin.url.path)
    }
}
