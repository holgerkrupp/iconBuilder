import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IconBuilderCore

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
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .pdf ? "Export vector PDF" : "Export PNG")
                .font(.headline)

            if kind == .pdf {
                Text("Vector PDF at \(Int(pdfSize)) pt. Paths and gradients stay vector.")
                    .font(.caption).foregroundStyle(.secondary)
                stepperRow("Size (pt)", value: $pdfSize, range: 16...4096, step: 64)
                Toggle("DeviceCMYK color (print)", isOn: $pdfCMYK)
                Toggle("Include cosmetic effects", isOn: $pdfEffects)
                    .help("Off keeps the file a clean, fully-vector separation. On adds soft shadows/gloss, which may rasterize.")
            } else {
                stepperRow("Size (px)", value: $pngSize, range: 16...4096, step: 128)
                Text("PNG is rasterized in sRGB for on-screen use.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let status { Text(status).font(.caption).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { runExport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func stepperRow(_ label: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .frame(width: 70).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }

    private func runExport() {
        let panel = NSSavePanel()
        let base = model.displayName
        if kind == .pdf {
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(base).pdf"
        } else {
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(base)-\(Int(pngSize)).png"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if kind == .pdf {
                try model.exportPDF(to: url, pointSize: CGFloat(pdfSize), cmyk: pdfCMYK, effects: pdfEffects)
            } else {
                try model.exportPNG(to: url, pixelSize: Int(pngSize))
            }
            dismiss()
        } catch {
            status = String(describing: error)
        }
    }
}
