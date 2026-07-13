import Foundation
import IconBuilderCore

// Headless validation harness:
//   rendertool <path-to.icon> <out-dir>
// Renders a matrix of appearances/recipes to PNG (and one CMYK PDF) so the
// compositing math can be checked visually without launching the GUI.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: rendertool <path.icon> [out-dir]\n".utf8))
    exit(2)
}
let iconURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath)

do {
    let doc = try IconDocument.load(bundleURL: iconURL)
    print("Loaded \(doc.displayName): \(doc.manifest.groups.count) groups, \(doc.shapes.count) assets")
    for (name, shape) in doc.shapes {
        print("  asset \(name): bbox \(shape.path.boundingBoxOfPath) viewBox \(shape.viewBox)")
    }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let recipes: [Recipe] = [.iOS26, .iOS27]
    let appearances: [Appearance] = [.light, .dark]
    for recipe in recipes {
        for appearance in appearances {
            let opts = RenderOptions(appearance: appearance, recipe: recipe,
                                     cmyk: false, effects: true)
            let name = "\(recipe.id)-\(appearance.rawValue).png"
            try Exporters.exportPNG(doc, to: outDir.appendingPathComponent(name),
                                    pixelSize: 512, options: opts)
            print("  wrote \(name)")
        }
    }
    // One CMYK vector PDF for print-path validation.
    let pdfOpts = RenderOptions(appearance: .light, recipe: .iOS26, cmyk: true, effects: false)
    try Exporters.exportPDF(doc, to: outDir.appendingPathComponent("ios26-light-cmyk.pdf"),
                            pointSize: 1024, options: pdfOpts)
    print("  wrote ios26-light-cmyk.pdf")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
