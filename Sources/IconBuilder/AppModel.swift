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
    var saveErrorMessage: String?
    var presentExport: ExportKind?
    private var synchronizingSelection = false
    var selection: NodeSelection = .document {
        didSet {
            if !synchronizingSelection {
                if case .layer(let g, let l) = selection, let layer = layer(g, l) {
                    selectedLayerIDs = [layer.id]
                } else {
                    selectedLayerIDs = []
                }
            }
            if selectedShape == nil { isShapeEditing = false }
        }
    }
    var selectedLayerIDs: Set<UUID> = []
    var isDirty = false
    var isShapeEditing = false
    var snapEnabled = true
    private var modifiedShapes: [String: EditableShape] = [:]

    private struct EditorSnapshot {
        var document: IconDocument
        var modifiedShapes: [String: EditableShape]
        var selection: NodeSelection
        var selectedLayerIDs: Set<UUID>
        var isDirty: Bool
        var isShapeEditing: Bool
    }
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var transactionSnapshot: EditorSnapshot?

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
            modifiedShapes = [:]
            isDirty = false
            isShapeEditing = false
            undoStack = []
            redoStack = []
            transactionSnapshot = nil
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

    func save() {
        guard let document else { return }
        do {
            try document.save(modifiedShapes: modifiedShapes)
            modifiedShapes = [:]
            isDirty = false
            saveErrorMessage = nil
            undoStack = []
            redoStack = []
            transactionSnapshot = nil
        } catch {
            saveErrorMessage = String(describing: error)
        }
    }

    private func changed() {
        isDirty = true
        scheduleRender()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canCombineSelectedShapes: Bool {
        guard selectedLayerIDs.count >= 2, let document else { return false }
        let vectorIDs = Set(document.manifest.groups.flatMap(\.layers).compactMap { layer in
            document.shapes[layer.imageName] == nil ? nil : layer.id
        })
        return selectedLayerIDs.isSubset(of: vectorIDs)
    }

    private func snapshot() -> EditorSnapshot? {
        guard let document else { return nil }
        return EditorSnapshot(document: document, modifiedShapes: modifiedShapes,
                              selection: selection, selectedLayerIDs: selectedLayerIDs,
                              isDirty: isDirty, isShapeEditing: isShapeEditing)
    }

    private func recordUndo() {
        guard transactionSnapshot == nil, let snapshot = snapshot() else { return }
        undoStack.append(snapshot)
        if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
        redoStack = []
    }

    func beginUndoTransaction() {
        if transactionSnapshot == nil { transactionSnapshot = snapshot() }
    }

    func endUndoTransaction() {
        guard let snapshot = transactionSnapshot else { return }
        transactionSnapshot = nil
        undoStack.append(snapshot)
        if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
        redoStack = []
    }

    func undo() {
        guard let target = undoStack.popLast(), let current = snapshot() else { return }
        redoStack.append(current)
        restore(target)
    }

    func redo() {
        guard let target = redoStack.popLast(), let current = snapshot() else { return }
        undoStack.append(current)
        restore(target)
    }

    private func restore(_ snapshot: EditorSnapshot) {
        document = snapshot.document
        modifiedShapes = snapshot.modifiedShapes
        selectedLayerIDs = snapshot.selectedLayerIDs
        synchronizingSelection = true
        selection = snapshot.selection
        synchronizingSelection = false
        isDirty = snapshot.isDirty
        isShapeEditing = snapshot.isShapeEditing && selectedShape != nil
        render()
    }

    func withManifest(_ body: (inout IconManifest) -> Void) {
        guard document != nil else { return }
        recordUndo()
        body(&document!.manifest)
        changed()
    }

    /// Mutate a group in place and re-render.
    func withGroup(_ g: Int, _ body: (inout IconBuilderCore.Group) -> Void) {
        guard document != nil, document!.manifest.groups.indices.contains(g) else { return }
        recordUndo()
        body(&document!.manifest.groups[g])
        changed()
    }

    /// Mutate a layer in place and re-render.
    func withLayer(_ g: Int, _ l: Int, _ body: (inout Layer) -> Void) {
        guard document != nil,
              document!.manifest.groups.indices.contains(g),
              document!.manifest.groups[g].layers.indices.contains(l) else { return }
        recordUndo()
        body(&document!.manifest.groups[g].layers[l])
        changed()
    }

    func group(_ g: Int) -> IconBuilderCore.Group? {
        guard let doc = document, doc.manifest.groups.indices.contains(g) else { return nil }
        return doc.manifest.groups[g]
    }

    func layer(_ g: Int, _ l: Int) -> Layer? {
        guard let grp = group(g), grp.layers.indices.contains(l) else { return nil }
        return grp.layers[l]
    }

    var sidebarSelections: Set<NodeSelection> {
        guard !selectedLayerIDs.isEmpty, let document else { return [selection] }
        var values: Set<NodeSelection> = []
        for (g, group) in document.manifest.groups.enumerated() {
            for (l, layer) in group.layers.enumerated() where selectedLayerIDs.contains(layer.id) {
                values.insert(.layer(g, l))
            }
        }
        return values.isEmpty ? [selection] : values
    }

    func setSidebarSelections(_ values: Set<NodeSelection>) {
        let layerSelections = values.compactMap { value -> (NodeSelection, UUID, Int, Int)? in
            guard case .layer(let g, let l) = value, let layer = layer(g, l) else { return nil }
            return (value, layer.id, g, l)
        }
        if !layerSelections.isEmpty, layerSelections.count == values.count {
            let ids = Set(layerSelections.map(\.1))
            let currentID: UUID? = {
                guard case .layer(let g, let l) = selection else { return nil }
                return layer(g, l)?.id
            }()
            let primary = layerSelections.first(where: { $0.1 == currentID })
                ?? layerSelections.sorted { ($0.2, $0.3) < ($1.2, $1.3) }.first!
            selectedLayerIDs = ids
            synchronizingSelection = true
            selection = primary.0
            synchronizingSelection = false
            return
        }

        if values.contains(.document) || values.isEmpty {
            selection = .document
        } else if let groupIndex = values.compactMap({ value -> Int? in
            if case .group(let g) = value { return g }
            return nil
        }).min() {
            selection = .group(groupIndex)
        }
    }

    var selectedShape: EditableShape? {
        guard case .layer(let g, let l) = selection,
              let layer = layer(g, l), layer.imageName.lowercased().hasSuffix(".svg") else { return nil }
        if let modified = modifiedShapes[layer.imageName] { return modified }
        guard let shape = document?.shapes[layer.imageName] else { return nil }
        return EditableShape(shape: shape)
    }

    func updateSelectedShape(_ shape: EditableShape) {
        guard case .layer(let g, let l) = selection, let layer = layer(g, l) else { return }
        recordUndo()
        modifiedShapes[layer.imageName] = shape
        document?.shapes[layer.imageName] = SVGShape(path: shape.path)
        changed()
    }

    /// Add a new SVG-backed layer to the selected group (or the top group).
    func addShape(_ kind: IconShapeKind) {
        guard document != nil else { return }
        recordUndo()
        let groupIndex: Int
        switch selection {
        case .group(let g), .layer(let g, _): groupIndex = g
        case .document: groupIndex = 0
        }
        if document!.manifest.groups.isEmpty {
            document!.manifest.groups.append(Group())
        }
        let targetGroup = min(groupIndex, document!.manifest.groups.count - 1)
        let base = kind.displayName.replacingOccurrences(of: " ", with: "-").lowercased()
        var counter = 1
        var assetName = "\(base).svg"
        let existing = Set(document!.manifest.groups.flatMap(\.layers).map(\.imageName))
        while existing.contains(assetName) || document!.shapes[assetName] != nil {
            counter += 1
            assetName = "\(base)-\(counter).svg"
        }

        let shape = EditableShape.starter(kind)
        let layer = Layer(name: kind.displayName, imageName: assetName,
                          fill: Specialized(base: .automaticGradient(
                            ColorSpec(space: .srgb, r: 0.22, g: 0.55, b: 1, a: 1))))
        document!.manifest.groups[targetGroup].layers.insert(layer, at: 0)
        document!.shapes[assetName] = SVGShape(path: shape.path)
        modifiedShapes[assetName] = shape
        selection = .layer(targetGroup, 0)
        isShapeEditing = true
        changed()
    }

    func addGroup() {
        guard document != nil else { return }
        recordUndo()
        document!.manifest.groups.insert(Group(), at: 0)
        selection = .group(0)
        changed()
    }

    func deleteSelection() {
        guard document != nil else { return }
        recordUndo()
        switch selection {
        case .document:
            return
        case .group(let g):
            guard document!.manifest.groups.indices.contains(g) else { return }
            let names = document!.manifest.groups[g].layers.map(\.imageName)
            document!.manifest.groups.remove(at: g)
            for name in names where !document!.manifest.groups.flatMap(\.layers).contains(where: { $0.imageName == name }) {
                document!.shapes.removeValue(forKey: name)
                modifiedShapes.removeValue(forKey: name)
            }
            selection = .document
        case .layer(let g, let l):
            guard document!.manifest.groups.indices.contains(g),
                  document!.manifest.groups[g].layers.indices.contains(l) else { return }
            let ids = selectedLayerIDs.isEmpty
                ? Set([document!.manifest.groups[g].layers[l].id]) : selectedLayerIDs
            let names = document!.manifest.groups.flatMap(\.layers)
                .filter { ids.contains($0.id) }.map(\.imageName)
            for groupIndex in document!.manifest.groups.indices {
                document!.manifest.groups[groupIndex].layers.removeAll { ids.contains($0.id) }
            }
            for name in names where !document!.manifest.groups.flatMap(\.layers)
                .contains(where: { $0.imageName == name }) {
                document!.shapes.removeValue(forKey: name)
                document!.images.removeValue(forKey: name)
                modifiedShapes.removeValue(forKey: name)
            }
            selection = .group(g)
        }
        isShapeEditing = false
        changed()
    }

    func moveLayer(id: UUID, toGroup targetGroup: Int, before targetIndex: Int) {
        guard document != nil, document!.manifest.groups.indices.contains(targetGroup) else { return }
        var source: (group: Int, layer: Int)?
        for (g, group) in document!.manifest.groups.enumerated() {
            if let l = group.layers.firstIndex(where: { $0.id == id }) { source = (g, l); break }
        }
        guard let source else { return }
        var effectiveIndex = max(0, min(targetIndex,
                                         document!.manifest.groups[targetGroup].layers.count))
        if source.group == targetGroup && source.layer < effectiveIndex { effectiveIndex -= 1 }
        if source.group == targetGroup && source.layer == effectiveIndex { return }
        recordUndo()
        guard let destination = document!.manifest.moveLayer(
            id: id, toGroup: targetGroup, before: targetIndex) else { return }
        selection = .layer(destination.group, destination.index)
        changed()
    }

    func importSVG() {
        guard document != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.svg]
        panel.message = "Choose SVG artwork to add as a new icon layer"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let imported = SVGShape.load(url: url) else {
            saveErrorMessage = "No vector geometry was found in \(url.lastPathComponent)."
            return
        }

        var transform = normalizationTransform(for: imported.viewBox)
        guard let path = imported.path.copy(using: &transform) else { return }
        let editable = EditableShape(shape: SVGShape(path: path))
        let groupIndex = targetGroupIndex()
        let base = url.deletingPathExtension().lastPathComponent
        let assetName = uniqueAssetName(base: base)
        let newLayer = Layer(name: base, imageName: assetName,
                             fill: Specialized(base: .automaticGradient(
                                ColorSpec(space: .srgb, r: 0.22, g: 0.55, b: 1, a: 1))))
        recordUndo()
        if document!.manifest.groups.isEmpty { document!.manifest.groups.append(Group()) }
        document!.manifest.groups[groupIndex].layers.insert(newLayer, at: 0)
        document!.shapes[assetName] = SVGShape(path: editable.path)
        modifiedShapes[assetName] = editable
        selection = .layer(groupIndex, 0)
        isShapeEditing = true
        changed()
    }

    func combineSelectedShapes(_ operation: ShapeBooleanOperation) {
        guard document != nil, selectedLayerIDs.count >= 2 else { return }
        var operands: [(g: Int, l: Int, layer: Layer, path: CGPath)] = []
        // Renderer order is back-to-front. That makes the first operand the
        // stable base for subtraction and for the resulting layer's style.
        for g in document!.manifest.groups.indices.reversed() {
            let group = document!.manifest.groups[g]
            for l in group.layers.indices.reversed() {
                let layer = group.layers[l]
                guard selectedLayerIDs.contains(layer.id),
                      let shape = document!.shapes[layer.imageName] else { continue }
                var transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                if let path = shape.path.copy(using: &transform) {
                    operands.append((g, l, layer, path))
                }
            }
        }
        guard operands.count == selectedLayerIDs.count, let base = operands.first else {
            NSSound.beep(); return
        }
        let result = operands.dropFirst().reduce(base.path) { operation.apply($0, $1.path) }
            .normalized(using: .winding)
        guard !result.boundingBoxOfPath.isNull, !result.boundingBoxOfPath.isEmpty else {
            NSSound.beep(); return
        }

        let baseGroupID = document!.manifest.groups[base.g].id
        var inverse = IconRenderer.layerCanvasTransform(
            layer: base.layer, group: document!.manifest.groups[base.g]).inverted()
        guard let rawResult = result.copy(using: &inverse) else { NSSound.beep(); return }
        let editable = EditableShape(shape: SVGShape(path: rawResult))

        recordUndo()
        for g in document!.manifest.groups.indices {
            document!.manifest.groups[g].layers.removeAll { selectedLayerIDs.contains($0.id) }
        }
        guard let resultGroup = document!.manifest.groups.firstIndex(where: { $0.id == baseGroupID }) else { return }
        var resultLayer = base.layer
        resultLayer.name = operation.displayName
        resultLayer.imageName = uniqueAssetName(base: operation.rawValue)
        let insertion = min(base.l, document!.manifest.groups[resultGroup].layers.count)
        document!.manifest.groups[resultGroup].layers.insert(resultLayer, at: insertion)
        document!.shapes[resultLayer.imageName] = SVGShape(path: rawResult)
        modifiedShapes[resultLayer.imageName] = editable
        selectedLayerIDs = [resultLayer.id]
        synchronizingSelection = true
        selection = .layer(resultGroup, insertion)
        synchronizingSelection = false
        isShapeEditing = true
        changed()
    }

    private func targetGroupIndex() -> Int {
        guard let document, !document.manifest.groups.isEmpty else { return 0 }
        switch selection {
        case .group(let g), .layer(let g, _): return min(g, document.manifest.groups.count - 1)
        case .document: return 0
        }
    }

    private func uniqueAssetName(base: String) -> String {
        let cleaned = base.lowercased().replacingOccurrences(
            of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = cleaned.isEmpty ? "shape" : cleaned
        let existing = Set(document?.manifest.groups.flatMap(\.layers).map(\.imageName) ?? [])
        var name = "\(stem).svg"
        var counter = 2
        while existing.contains(name) || document?.shapes[name] != nil {
            name = "\(stem)-\(counter).svg"; counter += 1
        }
        return name
    }

    private func normalizationTransform(for viewBox: CGRect) -> CGAffineTransform {
        guard viewBox.width > 0, viewBox.height > 0 else { return .identity }
        let scale = min(800 / viewBox.width, 800 / viewBox.height)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: (1024 - viewBox.width * scale) / 2 - viewBox.minX * scale,
                                 ty: (1024 - viewBox.height * scale) / 2 - viewBox.minY * scale)
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
