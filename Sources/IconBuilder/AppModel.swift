import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import IconBuilderCore

/// Observable state for the app: the loaded document, render options, the live
/// preview bitmap, and load/export actions.
@Observable
@MainActor
final class AppModel {
    var document: IconDocument?
    var errorMessage: String?
    var presentExport: ExportKind?
    var selection: NodeSelection = .document

    // Render options (drive the live preview and exports).
    var appearance: Appearance = .light {
        didSet { scheduleRender() }
    }
    var recipe: Recipe = .iOS26 {
        didSet { scheduleRender() }
    }
    var cmykPreview = false { didSet { scheduleRender() } }
    var effects = true { didSet { scheduleRender() } }
    var background = true { didSet { scheduleRender() } }
    var clipToMask = true { didSet { scheduleRender() } }

    var previewImage: CGImage?
    private(set) var previewSize = 640

    /// ICC output profile for CMYK conversion; persisted across launches.
    var printProfile: PrintProfile? {
        didSet {
            UserDefaults.standard.set(printProfile?.url.path, forKey: Self.profileDefaultsKey)
            scheduleRender()
        }
    }
    private static let profileDefaultsKey = "printICCProfilePath"

    /// ICC rendering intent (saturation keeps vivid artwork punchy).
    var renderingIntent: CGColorRenderingIntent = .saturation {
        didSet {
            UserDefaults.standard.set(Int(renderingIntent.rawValue), forKey: "printICCIntent")
            scheduleRender()
        }
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.profileDefaultsKey),
           let profile = try? PrintProfile.load(url: URL(fileURLWithPath: path)) {
            printProfile = profile
        }
        if UserDefaults.standard.object(forKey: "printICCIntent") != nil,
           let intent = CGColorRenderingIntent(rawValue: Int32(UserDefaults.standard.integer(forKey: "printICCIntent"))) {
            renderingIntent = intent
        }
    }

    /// Present an open panel to import an ICC profile. Returns an error
    /// message on failure, nil on success or cancel.
    func importICCProfile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let iccType = UTType("com.apple.colorsync-profile") {
            panel.allowedContentTypes = [iccType]
        }
        panel.message = "Choose your print service's ICC output profile (e.g. ISOcoated_v2_300_eci.icc)"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            printProfile = try PrintProfile.load(url: url)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    var options: RenderOptions {
        var profile = printProfile
        profile?.intent = renderingIntent
        return RenderOptions(appearance: appearance, recipe: recipe, cmyk: cmykPreview,
                             effects: effects, background: background, clipToMask: clipToMask,
                             printProfile: profile)
    }

    // MARK: Loading

    func open(url: URL) {
        do {
            let doc = try IconDocument.load(bundleURL: url)
            document = doc
            errorMessage = nil
            selection = .document
            render()
        } catch {
            document = nil
            previewImage = nil
            errorMessage = String(describing: error)
        }
    }

    // MARK: Rendering (debounced)

    private var renderTask: Task<Void, Never>?

    func scheduleRender() {
        guard document != nil else { return }
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return }
            render()
        }
    }

    func render() {
        guard let doc = document else { previewImage = nil; return }
        previewImage = Exporters.rasterize(doc, pixelSize: previewSize, options: options)
    }

    // MARK: Export

    func exportPDF(to url: URL, pointSize: CGFloat, cmyk: Bool, effects: Bool) throws {
        guard let doc = document else { return }
        var opts = options
        opts.cmyk = cmyk
        opts.effects = effects
        try Exporters.exportPDF(doc, to: url, pointSize: pointSize, options: opts)
    }

    func exportPNG(to url: URL, pixelSize: Int) throws {
        guard let doc = document else { return }
        try Exporters.exportPNG(doc, to: url, pixelSize: pixelSize, options: options)
    }

    func exportPrintPDF(to url: URL, print p: Exporters.PrintOptions, effects: Bool) throws {
        guard let doc = document else { return }
        var opts = options
        opts.effects = effects
        try Exporters.exportPrintPDF(doc, to: url, print: p, options: opts)
    }

    var displayName: String { document?.displayName ?? "No icon" }

    // MARK: - Node editing

    /// Mutate a group in place and re-render.
    func withGroup(_ g: Int, _ body: (inout IconBuilderCore.Group) -> Void) {
        guard document != nil, document!.manifest.groups.indices.contains(g) else { return }
        body(&document!.manifest.groups[g])
        scheduleRender()
    }

    /// Mutate a layer in place and re-render.
    func withLayer(_ g: Int, _ l: Int, _ body: (inout Layer) -> Void) {
        guard document != nil,
              document!.manifest.groups.indices.contains(g),
              document!.manifest.groups[g].layers.indices.contains(l) else { return }
        body(&document!.manifest.groups[g].layers[l])
        scheduleRender()
    }

    func group(_ g: Int) -> IconBuilderCore.Group? {
        guard let doc = document, doc.manifest.groups.indices.contains(g) else { return nil }
        return doc.manifest.groups[g]
    }

    func layer(_ g: Int, _ l: Int) -> Layer? {
        guard let grp = group(g), grp.layers.indices.contains(l) else { return nil }
        return grp.layers[l]
    }

    /// Apply a recipe's Liquid Glass defaults to the selected node (Icon
    /// Composer-style: glass on, specular, translucency and shadow at the
    /// preset's strengths). Layer selection also enables glass on the layer.
    func applyGlassPreset(_ recipe: Recipe, to selection: NodeSelection) {
        switch selection {
        case .document:
            self.recipe = recipe
        case .group(let g):
            withGroup(g) { grp in
                grp.specular = recipe.specularHighlight
                grp.translucency.setValue(Translucency(enabled: true, value: 0.5), for: appearance)
                grp.shadow = Shadow(kind: "neutral", opacity: recipe.layerShadowOpacity + 0.2)
            }
        case .layer(let g, let l):
            withLayer(g, l) { lyr in
                lyr.glass.setValue(true, for: appearance)
            }
            withGroup(g) { grp in
                grp.specular = recipe.specularHighlight
            }
        }
    }
}

/// What is selected in the sidebar tree.
enum NodeSelection: Hashable {
    case document
    case group(Int)
    case layer(Int, Int)
}
