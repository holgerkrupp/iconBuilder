import SwiftUI
import UniformTypeIdentifiers
import IconBuilderCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SidebarPane(model: model)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            PreviewPane(model: model)
                .frame(minWidth: 420)
            InspectorPane(model: model)
                .frame(width: 300)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { openIcon() } label: { Label("Open", systemImage: "folder") }
            }
            ToolbarItem {
                Button { model.presentExport = .pdf } label: { Label("Export PDF", systemImage: "doc.richtext") }
                    .disabled(model.document == nil)
            }
            ToolbarItem {
                Button { model.presentExport = .png } label: { Label("Export PNG", systemImage: "photo") }
                    .disabled(model.document == nil)
            }
            ToolbarItem {
                Button { model.presentExport = .print } label: { Label("Print-Ready PDF", systemImage: "printer") }
                    .disabled(model.document == nil)
            }
        }
        .navigationTitle(model.displayName)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
        .onAppear {
            // A file delivered as an open-file event before the window existed.
            if model.document == nil, let pending = AppDelegate.pendingOpenURL {
                AppDelegate.pendingOpenURL = nil
                model.open(url: pending)
                return
            }
            // Auto-open an .icon passed on the command line (CLI / Finder "Open With").
            if model.document == nil,
               let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".icon") }) {
                model.open(url: URL(fileURLWithPath: path))
            }
        }
        .sheet(item: Binding(get: { model.presentExport }, set: { model.presentExport = $0 })) { kind in
            ExportSheet(model: model, kind: kind)
        }
    }

    private func openIcon() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Apple .icon bundle"
        if panel.runModal() == .OK, let url = panel.url { model.open(url: url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { model.open(url: url) } }
        }
        return true
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            CheckerboardBackground()
            if let cg = model.previewImage {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 512, height: 512)))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(40)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            } else {
                EmptyPreview(error: model.errorMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { appearanceBar }
    }

    private var appearanceBar: some View {
        Picker("", selection: $model.appearance) {
            ForEach(Appearance.allCases, id: \.self) { a in
                Text(a.rawValue.capitalized).tag(a)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 340)
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 16)
        .disabled(model.document == nil)
    }
}

struct EmptyPreview: View {
    let error: String?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: error == nil ? "square.dashed" : "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text(error ?? "Drop an .icon bundle here, or use Open")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 16
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) {
                    let odd = (Int(x / s) + Int(y / s)) % 2 == 0
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                             with: .color(odd ? Color(white: 0.18) : Color(white: 0.22)))
                }
            }
        }
        .ignoresSafeArea()
    }
}
