import SwiftUI
import UniformTypeIdentifiers
import ShapeEditingUI

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage(IconBuilderOnboarding.releaseDefaultsKey)
    private var lastSeenOnboardingRelease = 0
    @State private var showsLayers = true
    @State private var showsInspector = true
    @State private var recentDocuments = RecentDocumentStore.shared
    @State private var navigator = IconNavigator.shared
    @State private var onboardingPresented = false

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
            ToolbarItem(placement: .navigation) {
                Button { openIcon() } label: { Label("Open", systemImage: "folder") }
                    .accessibilityLabel("Open icon document")
                    .help("Open an Apple .icon bundle.")
            }
            ToolbarItem {
                Button {
                    model.requirePro { model.saveBackToOrigin() }
                } label: {
                    Label("Save Back", systemImage: "arrow.uturn.backward.square")
                }
                .disabled(model.document == nil || !model.hasOrigin)
                .accessibilityLabel("Save back to the original icon document")
                .help(model.document == nil ? "Import a document first."
                      : !model.hasOrigin ? "This project has no original to write back to. Use Export Editable .icon… instead."
                      : "Write your edits into the original .icon bundle. Requires IconBuilder Pro. Your work is autosaved either way.")
                .overlay(alignment: .topTrailing) { ProBadge() }
            }
            ToolbarItem {
                Menu {
                    ForEach(IconShapeKind.allCases.filter { $0 != .path }) { kind in
                        Button { model.addShape(kind) } label: {
                            Label(kind.displayName, systemImage: kind.systemImage)
                        }
                    }
                    Divider()
                    Button("New Empty Layer", systemImage: "square.stack.3d.up.badge.automatic") {
                        model.addEmptyLayer()
                    }
                    Button("New Group", systemImage: "folder.badge.plus") { model.addGroup() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(model.document == nil)
                .accessibilityLabel("Add layer or group")
                .help("Add a shape layer or a group to the current document.")
            }
            ToolbarItem {
                Button {
                    model.presentExport = .pdf
                } label: { Label("Export PDF", systemImage: "doc.richtext") }
                    .disabled(model.document == nil)
                    .accessibilityLabel("Export icon as PDF")
                    .help("Export the current icon document as a PDF.")
            }
            ToolbarItem {
                Button {
                    model.presentExport = .png
                } label: { Label("Export PNG", systemImage: "photo") }
                    .disabled(model.document == nil)
                    .accessibilityLabel("Export icon as PNG")
                    .help("Export the current icon document as a PNG image.")
            }
            ToolbarItem {
                Button {
                    model.presentExport = .print
                } label: { Label("Print-Ready PDF", systemImage: "printer") }
                    .disabled(model.document == nil)
                    .accessibilityLabel("Export print-ready PDF")
                    .help("Export the current icon document as a print-ready PDF.")
            }
        
    }

    var body: some View {
        ShapeEditorWorkspace(
            leftWidth: 230,
            rightWidth: 320,
            showsLayers: $showsLayers,
            showsInspector: $showsInspector,
            layers: {
                SidebarPane(model: model)
            },
            toolbar: {
                IconShapeEditRow(model: model)
                    .disabled(model.document == nil)
            },
            editor: {
                if model.selectedShape != nil {
                    ShapeEditorView(model: model)
                } else {
                    PreviewPane(model: model)
                }
            },
            inspector: {
                InspectorPane(model: model)
            }
        )
        .toolbar { toolbarContent }
        .navigationTitle(model.displayName)
        .focusedSceneValue(\.shapeEditorCommandActions, shapeCommandActions)
        .focusedSceneValue(\.shapeEditorWorkspaceCommandActions, workspaceCommandActions)
        .focusedSceneValue(\.recentDocumentCommandActions, recentDocumentCommandActions)
        .background(WindowCloseGuard(model: model))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
        .onAppear {
            presentOnboardingIfNeeded()

            // A file delivered as an open-file event before the window existed.
            if model.document == nil, let pending = AppDelegate.pendingOpenURL {
                AppDelegate.pendingOpenURL = nil
                model.requestOpen(url: pending)
                return
            }
            // Auto-open an .icon passed on the command line (CLI / Finder "Open With").
            if model.document == nil,
               let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".icon") }) {
                model.requestOpen(url: URL(fileURLWithPath: path))
                return
            }
            // An App Intent may have launched us to open a project or show the
            // paywall; it parked the request before any window existed.
            if navigator.projectToOpen != nil || navigator.shouldShowPaywall {
                navigator.deliver()
                return
            }
            // Otherwise bring back whatever was open last — after a clean quit
            // or a crash alike. Never gated, never prompts.
            model.restoreLastSession()
        }
        .modifier(DocumentSheetsAndAlerts(model: model, onboardingPresented: $onboardingPresented))
    }

    private func presentOnboardingIfNeeded() {
        guard IconBuilderOnboardingPresentation.shared.claimAutomaticPresentation(
            lastSeenRelease: lastSeenOnboardingRelease
        ) else { return }

        onboardingPresented = true
    }

    private func openIcon() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Apple .icon bundle"
        if panel.runModal() == .OK, let url = panel.url { model.requestOpen(url: url) }
    }

    private var shapeCommandActions: ShapeEditorCommandActions {
        ShapeEditorCommandActions(
            canAddShapes: model.document != nil,
            hasSelection: !model.selectedLayerIDs.isEmpty,
            canCombineShapes: model.canCombineSelectedShapes,
            canSplitShapes: model.canSplitSelectedShapes,
            canCreateShapesFromHoles: model.canCreateShapesFromHoles,
            canDistributeShapes: model.canDistributeSelectedObjects,
            snappingEnabled: model.snapEnabled,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            addShape: { quickShape in
                switch quickShape {
                case .line: model.addShape(.line)
                case .text: model.addShape(.text)
                case .rectangle: model.addShape(.rectangle)
                case .ellipse: model.addShape(.ellipse)
                case .star: model.addShape(.star)
                }
            },
            importSVG: model.importSVG,
            booleanOperation: model.combineSelectedShapes,
            distributeShapes: model.distributeSelectedObjects,
            canArrangeShapes: !model.selectedLayerIDs.isEmpty,
            selectionOperation: model.performSelectionOperation,
            canvasTool: model.canvasTool,
            setCanvasTool: { model.canvasTool = $0 },
            deleteSelection: model.deleteSelection,
            toggleSnapping: { model.snapEnabled.toggle() },
            undo: model.undo,
            redo: model.redo
        )
    }

    private var workspaceCommandActions: ShapeEditorWorkspaceCommandActions {
        ShapeEditorWorkspaceCommandActions(
            layersVisible: showsLayers,
            inspectorVisible: showsInspector,
            toggleLayers: { showsLayers.toggle() },
            toggleInspector: { showsInspector.toggle() }
        )
    }

    private var recentDocumentCommandActions: RecentDocumentCommandActions {
        RecentDocumentCommandActions(
            urls: recentDocuments.urls,
            open: model.requestOpen,
            clear: recentDocuments.clear
        )
    }

    /// A dropped `.svg` becomes a new layer in the open project; anything else
    /// is treated as a document to open. Several SVGs at once each import.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if url.pathExtension.lowercased() == "svg", model.document != nil {
                        model.importSVG(from: url)
                    } else {
                        model.requestOpen(url: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @Bindable var model: AppModel
    @FocusState private var canvasFocused: Bool

    /// Matches the image's `.padding(40)` so view points and the 1024-point
    /// icon canvas line up for hit testing and selection outlines.
    private static let canvasInset: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let display = Self.canvasTransform(for: geometry.size)
            ZStack {
                CheckerboardBackground()
                if let cg = model.previewImage {
                    Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 512, height: 512)))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(Self.canvasInset)
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                        .accessibilityLabel("Rendered preview of \(model.displayName) in the \(model.appearance.rawValue) appearance")
                } else {
                    EmptyPreview(error: model.errorMessage)
                }
                Canvas { context, _ in
                    drawSelection(context: context, display: display)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard model.document != nil else { return }
                canvasFocused = true
                let modifiers = NSEvent.modifierFlags
                let scale = sqrt(abs(display.a * display.d - display.b * display.c))
                model.selectLayer(at: location.applying(display.inverted()),
                                  tolerance: 6 / max(scale, 0.01),
                                  extend: modifiers.contains(.shift),
                                  toggle: modifiers.contains(.command))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onDeleteCommand { model.deleteSelection() }
        .overlay(alignment: .bottom) { AppearanceSwitcherBar(model: model) }
    }

    static func canvasTransform(for size: CGSize) -> CGAffineTransform {
        let scale = max(0.01, (min(size.width, size.height) - 2 * canvasInset) / 1024)
        return CGAffineTransform.identity
            .translatedBy(x: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -512, y: -512)
    }

    /// Outline every selected layer so canvas selection is visible even when
    /// the vector editing surface is not up.
    private func drawSelection(context: GraphicsContext, display: CGAffineTransform) {
        guard let document = model.document, !model.selectedLayerIDs.isEmpty else { return }
        for group in document.manifest.groups where !group.hidden {
            for layer in group.layers where model.selectedLayerIDs.contains(layer.id) {
                var transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                    .concatenating(display)
                if let shape = document.shapes[layer.imageName],
                   let path = shape.path.copy(using: &transform) {
                    context.stroke(Path(path), with: .color(.accentColor),
                                   style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                } else if document.images[layer.imageName] != nil {
                    let box = CGRect(x: 0, y: 0, width: 1024, height: 1024)
                        .applying(transform)
                    context.stroke(Path(box), with: .color(.accentColor),
                                   style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
        }
    }
}

struct AppearanceSwitcherBar: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("", selection: $model.appearance) {
            ForEach(Appearance.allCases, id: \.self) { appearance in
                Text(appearance.rawValue.capitalized).tag(appearance)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Preview appearance")
        .help("Choose the appearance to preview and edit in appearance-specific inspector controls.")
        .frame(maxWidth: 340)
        .padding(10)
        .shapeEditorGlassCapsule(interactive: true)
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

/// The window's sheets and alerts, pulled out of `ContentView.body` so the
/// type checker can cope with the size of the chain.
private struct DocumentSheetsAndAlerts: ViewModifier {
    @Bindable var model: AppModel
    @Binding var onboardingPresented: Bool

    func body(content: Content) -> some View {
        content
    .sheet(item: Binding(get: { model.presentExport }, set: { model.presentExport = $0 })) { kind in
        ExportSheet(model: model, kind: kind)
    }
    .sheet(isPresented: $onboardingPresented) {
        IconBuilderOnboardingView()
    }
    .sheet(item: Binding(get: { model.presentPaywall },
                         set: { model.presentPaywall = $0 }),
           onDismiss: { model.paywallDismissed() }) { reason in
        PaywallView(reason: reason) { model.armPendingProAction() }
    }
    .alert("Operation Failed", isPresented: Binding(
        get: { model.saveErrorMessage != nil },
        set: { if !$0 { model.saveErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
    } message: {
        Text(model.saveErrorMessage ?? "Unknown error")
    }
    .alert("Could Not Open", isPresented: Binding(
        get: { model.openErrorMessage != nil },
        set: { if !$0 { model.openErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
    } message: {
        Text(model.openErrorMessage ?? "Unknown error")
    }
    .alert("Document Opened with Warnings", isPresented: Binding(
        get: { model.documentWarningsMessage != nil },
        set: { if !$0 { model.documentWarningsMessage = nil } })) {
            Button("OK", role: .cancel) {}
    } message: {
        Text(model.documentWarningsMessage ?? "")
    }
    }
}
