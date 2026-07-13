import Foundation
import SwiftUI
import CoreGraphics
import IconBuilderCore

/// Observable state for the app: the loaded document, render options, the live
/// preview bitmap, and load/export actions.
@Observable
@MainActor
final class AppModel {
    var document: IconDocument?
    var errorMessage: String?
    var presentExport: ExportKind?

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

    var options: RenderOptions {
        RenderOptions(appearance: appearance, recipe: recipe, cmyk: cmykPreview,
                      effects: effects, background: background, clipToMask: clipToMask)
    }

    // MARK: Loading

    func open(url: URL) {
        do {
            let doc = try IconDocument.load(bundleURL: url)
            document = doc
            errorMessage = nil
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

    var displayName: String { document?.displayName ?? "No icon" }
}
