import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

// Debug: dump the recipe mask as a PNG for geometry validation.
if let dump = ProcessInfo.processInfo.environment["ICONBUILDER_DUMP_MASK"] {
    let S = 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.addPath(Recipe.iOS26.maskPath(in: CGRect(x: 0, y: 0, width: S, height: S)))
    ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
    ctx.fillPath()
    if let img = ctx.makeImage(),
       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dump) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("mask dumped to \(dump)")
    }
    exit(0)
}

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
                                    pixelSize: 1024, options: opts)
            print("  wrote \(name)")
        }
    }
    // One CMYK vector PDF for print-path validation. Set ICONBUILDER_ICC to an
    // ICC profile path for profile-accurate conversion.
    var iccProfile: PrintProfile? = nil
    if let iccPath = ProcessInfo.processInfo.environment["ICONBUILDER_ICC"] {
        iccProfile = try PrintProfile.load(url: URL(fileURLWithPath: iccPath))
        print("using ICC profile: \(iccProfile!.name)")
    }
    let pdfOpts = RenderOptions(appearance: .light, recipe: .iOS26, cmyk: true, effects: false,
                                printProfile: iccProfile)
    try Exporters.exportPDF(doc, to: outDir.appendingPathComponent("ios26-light-cmyk.pdf"),
                            pointSize: 1024, options: pdfOpts)
    print("  wrote ios26-light-cmyk.pdf")

    // Print-ready PDF: 50 mm + 3 mm bleed, cut line, glass effects.
    let printOpts = Exporters.PrintOptions(targetSizeMM: 50, bleedMM: 3)
    var printRender = pdfOpts
    printRender.effects = true
    try Exporters.exportPrintPDF(doc, to: outDir.appendingPathComponent("print-50mm-3mm.pdf"),
                                 print: printOpts, options: printRender)
    print("  wrote print-50mm-3mm.pdf")

    // Same, flattened to a 300 dpi CMYK bitmap.
    let flatOpts = Exporters.PrintOptions(targetSizeMM: 50, bleedMM: 3, dpi: 300, flatten: true)
    try Exporters.exportPrintPDF(doc, to: outDir.appendingPathComponent("print-50mm-3mm-flat300.pdf"),
                                 print: flatOpts, options: pdfOpts)
    print("  wrote print-50mm-3mm-flat300.pdf")

    // Hybrid: Icon Composer PNG in the trim area (set ICONBUILDER_PNG).
    if let pngPath = ProcessInfo.processInfo.environment["ICONBUILDER_PNG"] {
        let hybridOpts = Exporters.PrintOptions(targetSizeMM: 50, bleedMM: 3,
                                                artworkPNGURL: URL(fileURLWithPath: pngPath))
        try Exporters.exportPrintPDF(doc, to: outDir.appendingPathComponent("print-50mm-3mm-hybrid.pdf"),
                                     print: hybridOpts, options: printRender)
        print("  wrote print-50mm-3mm-hybrid.pdf")
        var hybridRGB = hybridOpts
        hybridRGB.rgb = true
        try Exporters.exportPrintPDF(doc, to: outDir.appendingPathComponent("print-50mm-3mm-hybrid-rgb.pdf"),
                                     print: hybridRGB, options: printRender)
        print("  wrote print-50mm-3mm-hybrid-rgb.pdf")
    }

    // RGB variant (full gamut; the print service converts).
    let rgbOpts = Exporters.PrintOptions(targetSizeMM: 50, bleedMM: 3, rgb: true)
    try Exporters.exportPrintPDF(doc, to: outDir.appendingPathComponent("print-50mm-3mm-rgb.pdf"),
                                 print: rgbOpts, options: printRender)
    print("  wrote print-50mm-3mm-rgb.pdf")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
