import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShapeEditingUI

struct ExportSheet: View {
    @Bindable var model: AppModel
    let kind: ExportKind
    @Environment(\.dismiss) private var dismiss

    // PDF options
    @State private var pdfSize: Double = 1024
    @State private var pdfCMYK = true
    @State private var pdfEffects = false
    // PNG options
    @State private var pngSize: Double = 1024
    // Print options
    @State private var printSizeMM: Double = 50
    @State private var printBleedMM: Double = 3
    @State private var printDPI: Double = 300
    @State private var printFlatten = false
    @State private var printCutLine = true
    @State private var printEffects = true
    @State private var printRGB = false
    @State private var printPNGURL: URL?
    @State private var printShape: Exporters.PrintOptions.Shape = .icon
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .pdf ? "Export vector PDF" : kind == .png ? "Export PNG" : "Export print-ready PDF")
                .font(.headline)

            if kind == .pdf {
                Text("Vector PDF at \(Int(pdfSize)) pt. Paths and gradients stay vector.")
                    .font(.caption).foregroundStyle(.secondary)
                stepperRow("Size (pt)", value: $pdfSize, range: 16...4096, step: 64)
                Toggle("DeviceCMYK color (print)", isOn: $pdfCMYK)
                if pdfCMYK { profileRow; intentRow }
                Toggle("Include cosmetic effects", isOn: $pdfEffects)
                    .help("Off keeps the file a clean, fully-vector separation. On adds soft shadows/gloss, which may rasterize.")
            } else if kind == .png {
                stepperRow("Size (px)", value: $pngSize, range: 16...4096, step: 128)
                Text("PNG is rasterized in Display P3 to match Icon Composer output.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let page = printSizeMM + 2 * printBleedMM
                Text("\(printRGB ? "sRGB" : "DeviceCMYK") PDF with seamless bleed and a CutContour spot-color die line. "
                     + "Page: \(page.formatted(.number.precision(.fractionLength(0...1)))) × "
                     + "\(page.formatted(.number.precision(.fractionLength(0...1)))) mm, "
                     + "TrimBox on the finished size.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 20) {
                    printPreview
                        .frame(width: 280)
                    Divider()
                    printSettings
                        .frame(width: 380)
                }
            }

            if let message = validationMessage ?? status {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .shapeEditorGlassPanel(cornerRadius: 24)
        .padding(12)
        .frame(width: kind == .print ? 720 : 420)
    }

    private var printSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepperRow("Icon size (mm)", value: $printSizeMM, range: 10...500, step: 5)
            stepperRow("Bleed (mm)", value: $printBleedMM, range: 0...20, step: 0.5)
            LabeledContent("Shape") {
                Picker("", selection: $printShape) {
                    ForEach(Exporters.PrintOptions.Shape.allCases) { shape in
                        Text(shape.name).tag(shape)
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Export shape")
            }
            .help("Sets both the finished artwork mask and the CutContour die line.")
            LabeledContent("Artwork") {
                Menu {
                    Button("Rendered from .icon (vector)") { printPNGURL = nil }
                    Button("Choose Icon Composer PNG…") { choosePNG() }
                    if let u = printPNGURL {
                        Divider()
                        Label(u.lastPathComponent, systemImage: "checkmark")
                    }
                } label: {
                    Text(printPNGURL?.lastPathComponent ?? "Rendered from .icon (vector)")
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .help("Use Apple's own Icon Composer PNG export for the trim area — a pixel-exact match with the system render (raster). The bleed stays vector; the seam falls on the cut line.")
            LabeledContent("Color") {
                Picker("", selection: $printRGB) {
                    Text("CMYK (prepress)").tag(false)
                    Text("RGB (sRGB)").tag(true)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Print artwork color space")
            }
            .help("CMYK for classic prepress workflows. RGB keeps the full gamut and lets the print service convert with their own profiles — check what your shop prefers.")
            if !printRGB { profileRow; intentRow }
            Toggle("Cut line (CutContour spot color)", isOn: $printCutLine)
                .help("The die-cut contour as a /Separation spot color named CutContour on its own PDF layer — the format most print services expect.")
            Toggle("Liquid Glass effects", isOn: $printEffects)
                .help("Vector-only glass lighting (rim, glow, translucency) so the print matches the on-screen icon. Off exports flat fills.")
            Toggle("Flatten to raster", isOn: $printFlatten)
                .help("Rasterizes the artwork into a CMYK bitmap at the resolution below. The cut line stays vector.")
            stepperRow("Resolution (dpi)", value: $printDPI, range: 72...1200, step: 50)
                .disabled(!printFlatten)
                .opacity(printFlatten ? 1 : 0.5)
        }
    }

    private var printPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let inset = side * CGFloat(printBleedMM / max(printSizeMM + 2 * printBleedMM, 1))
                let trimRect = CGRect(x: inset, y: inset,
                                      width: side - 2 * inset, height: side - 2 * inset)
                ZStack {
                    Color.white
                    if let image = printPreviewImage {
                        Image(image, scale: 1, label: Text("Print export preview"))
                            .resizable()
                            .interpolation(.high)
                    }
                    if printCutLine {
                        Canvas { context, _ in
                            var recipe = model.options.recipe
                            switch printShape {
                            case .icon: break
                            case .square: recipe.mask = .square
                            case .roundedSquare:
                                recipe.mask = .roundedRect
                                recipe.cornerFraction = 0.16
                            case .circle: recipe.mask = .circle
                            }
                            context.stroke(Path(recipe.maskPath(in: trimRect)),
                                           with: .color(Color(red: 1, green: 0, blue: 1)),
                                           lineWidth: 1)
                        }
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            .frame(height: 280)
            Text("Magenta indicates the CutContour spot-color line.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var printPreviewImage: CGImage? {
        guard let document = model.document else { return nil }
        var options = model.options
        options.effects = printEffects
        let print = Exporters.PrintOptions(targetSizeMM: printSizeMM, bleedMM: printBleedMM,
                                           cutLine: printCutLine, rgb: printRGB,
                                           artworkPNGURL: printPNGURL, shape: printShape)
        return Exporters.printPreview(document, print: print, options: options)
    }

    /// CMYK profile picker: the built-in formula or an imported ICC profile
    /// (e.g. the print service's ISO Coated v2 300%).
    private var profileRow: some View {
        LabeledContent("CMYK profile") {
            Menu {
                Button("Built-in (no ICC)") { model.printProfile = nil }
                Button("Import ICC Profile…") {
                    if let error = model.importICCProfile() { status = error }
                }
                if let p = model.printProfile {
                    Divider()
                    Label(p.name, systemImage: "checkmark")
                }
            } label: {
                Text(model.printProfile?.name ?? "Built-in (no ICC)")
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .help("Import your print service's ICC output profile (e.g. ISOcoated_v2_300_eci.icc) for profile-accurate CMYK. Remembered across launches.")
    }

    @ViewBuilder
    private var intentRow: some View {
        if model.printProfile != nil {
            LabeledContent("Intent") {
                Picker("", selection: Binding(
                    get: { model.renderingIntent },
                    set: { model.renderingIntent = $0 })) {
                    Text("Saturation (vivid)").tag(CGColorRenderingIntent.saturation)
                    Text("Perceptual").tag(CGColorRenderingIntent.perceptual)
                    Text("Relative Colorimetric").tag(CGColorRenderingIntent.relativeColorimetric)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("CMYK rendering intent")
            }
            .help("How out-of-gamut screen colors map to printable ink. Saturation keeps flat vivid artwork punchy; colorimetric is most exact for in-gamut colors.")
        }
    }

    private func choosePNG() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png]
        panel.message = "Choose an Icon Composer PNG export (e.g. AppIcon-iOS-Default-1024@1x.png)"
        if panel.runModal() == .OK, let url = panel.url { printPNGURL = url }
    }

    private func stepperRow(_ label: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .frame(width: 70).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .accessibilityLabel(label)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel("Adjust \(label)")
        }
    }

    private var validationMessage: String? {
        switch kind {
        case .pdf:
            guard pdfSize.isFinite, (1...16_384).contains(pdfSize) else {
                return "PDF size must be between 1 and 16,384 points."
            }
        case .png:
            guard pngSize.isFinite, (1...8_192).contains(pngSize) else {
                return "PNG size must be between 1 and 8,192 pixels."
            }
        case .print:
            guard printSizeMM.isFinite, printSizeMM > 0,
                  printBleedMM.isFinite, printBleedMM >= 0,
                  printDPI.isFinite, printDPI > 0 else {
                return "Print size and resolution must be positive; bleed cannot be negative."
            }
            if printFlatten {
                let pixels = ((printSizeMM + 2 * printBleedMM) / 25.4 * printDPI).rounded()
                guard pixels.isFinite, pixels >= 1, pixels <= 8_192 else {
                    return "Flattened artwork would be \(pixels.formatted()) pixels wide. Reduce its size or resolution to 8,192 pixels or less."
                }
            }
        }
        return nil
    }

    private func runExport() {
        guard validationMessage == nil else { return }
        let panel = NSSavePanel()
        let base = model.displayName
        switch kind {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(base).pdf"
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(base)-\(Int(pngSize)).png"
        case .print:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(base)-print-\(Int(printSizeMM))mm\(printRGB ? "-rgb" : "").pdf"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .pdf:
                try model.exportPDF(to: url, pointSize: CGFloat(pdfSize), cmyk: pdfCMYK, effects: pdfEffects)
            case .png:
                try model.exportPNG(to: url, pixelSize: Int(pngSize))
            case .print:
                let p = Exporters.PrintOptions(targetSizeMM: printSizeMM, bleedMM: printBleedMM,
                                               dpi: printDPI, flatten: printFlatten,
                                               cutLine: printCutLine, rgb: printRGB,
                                               artworkPNGURL: printPNGURL, shape: printShape)
                try model.exportPrintPDF(to: url, print: p, effects: printEffects)
            }
            dismiss()
        } catch {
            status = String(describing: error)
        }
    }
}
