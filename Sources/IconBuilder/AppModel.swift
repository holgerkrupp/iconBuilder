import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ShapeEditingUI

/// Observable state for the app: the loaded document, render options, the live
/// preview bitmap, and load/export actions.
@Observable
@MainActor
final class AppModel {
    private static let layerPasteboardType =
        NSPasteboard.PasteboardType("com.holgerkrupp.iconbuilder.layers")

    private struct LayerClipboardPayload: Codable {
        var layers: [LayerClipboardItem]
    }

    struct SelectionCanvasItem: Sendable {
        var group: Int
        var layer: Int
        var bounds: CGRect
    }

    struct SelectionBoundsSnapshot: Sendable {
        var bounds: CGRect
        var items: [SelectionCanvasItem]
    }

    private struct LayerClipboardItem: Codable {
        var layer: Layer
        var asset: LayerClipboardAsset
    }

    private enum LayerClipboardAsset: Codable {
        case svg(Data)
        case rasterPNG(Data)

        private enum CodingKeys: String, CodingKey {
            case kind
            case data
        }

        private enum Kind: String, Codable {
            case svg
            case rasterPNG
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)
            let data = try container.decode(Data.self, forKey: .data)
            switch kind {
            case .svg: self = .svg(data)
            case .rasterPNG: self = .rasterPNG(data)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .svg(let data):
                try container.encode(Kind.svg, forKey: .kind)
                try container.encode(data, forKey: .data)
            case .rasterPNG(let data):
                try container.encode(Kind.rasterPNG, forKey: .kind)
                try container.encode(data, forKey: .data)
            }
        }
    }

    var document: IconDocument?
    /// The library project whose working copy `document` was loaded from.
    var project: LibraryProject?
    var errorMessage: String?
    var openErrorMessage: String?
    var documentWarningsMessage: String?
    var saveErrorMessage: String?
    var presentExport: ExportKind?

    // MARK: Pro gate

    /// Non-nil while the paywall sheet is up.
    var presentPaywall: PaywallReason?
    /// The action the paywall interrupted, replayed on a successful purchase.
    private var pendingProAction: (() -> Void)?

    /// Run `action` if Pro is unlocked, otherwise raise the paywall and run it
    /// after a successful purchase or restore.
    ///
    /// Every gated entry point funnels through here, which is what keeps the
    /// paywall in front of the save panel rather than behind it — nobody picks
    /// a filename and *then* discovers they cannot write it.
    func requirePro(_ action: @escaping () -> Void) {
        guard StoreManager.shared.isUnlocked else {
            pendingProAction = action
            presentPaywall = .gatedAction
            return
        }
        action()
    }

    /// Set by the paywall on a successful purchase or restore. The action is
    /// not run until the sheet is actually gone, so the save panel it usually
    /// opens isn't fighting the sheet for the window.
    private var proActionArmed = false

    func armPendingProAction() {
        proActionArmed = true
    }

    /// Called when the paywall sheet is dismissed, however it was dismissed.
    func paywallDismissed() {
        let action = pendingProAction
        let armed = proActionArmed
        pendingProAction = nil
        proActionArmed = false
        if armed { action?() }
    }
    private var synchronizingSelection = false
    var selection: NodeSelection = .document {
        didSet {
            selectedPathHandle = nil
            if !synchronizingSelection {
                if case .layer(let g, let l) = selection, let layer = layer(g, l) {
                    selectedLayerIDs = [layer.id]
                    layerSelectionAnchorID = layer.id
                } else if case .group(let g) = selection, let group = group(g) {
                    selectedLayerIDs = Set(group.layers.map(\.id))
                    layerSelectionAnchorID = group.layers.first?.id
                } else {
                    selectedLayerIDs = []
                    layerSelectionAnchorID = nil
                }
            }
            reconcileShapeEditingState()
        }
    }
    var selectedLayerIDs: Set<UUID> = [] {
        didSet {
            if let layerSelectionAnchorID,
               !selectedLayerIDs.contains(layerSelectionAnchorID) {
                self.layerSelectionAnchorID = selectedLayerIDs.first
            }
        }
    }
    private var layerSelectionAnchorID: UUID?
    var isDirty = false {
        didSet { if isDirty { scheduleAutosave() } }
    }
    var isShapeEditing = false
    var snapEnabled = true
    var canvasTool: ShapeCanvasTool = .select
    var selectedPathHandle: VectorPathHandle?
    var canvasSettings = ShapeCanvasSettings()
    private var modifiedShapes: [String: EditableShape] = [:]
    private var modifiedImages: [String: CGImage] = [:]

    private struct EditorSnapshot {
        var document: IconDocument
        var modifiedShapes: [String: EditableShape]
        var modifiedImages: [String: CGImage]
        var selection: NodeSelection
        var selectedLayerIDs: Set<UUID>
        var layerSelectionAnchorID: UUID?
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
            if printProfile == nil {
                UserDefaults.standard.removeObject(forKey: Self.profileBookmarkDefaultsKey)
                UserDefaults.standard.removeObject(forKey: Self.legacyProfilePathDefaultsKey)
            }
            scheduleRender()
        }
    }
    private static let profileBookmarkDefaultsKey = "printICCProfileBookmark"
    private static let legacyProfilePathDefaultsKey = "printICCProfilePath"

    /// ICC rendering intent (saturation keeps vivid artwork punchy).
    var renderingIntent: CGColorRenderingIntent = .saturation {
        didSet {
            UserDefaults.standard.set(Int(renderingIntent.rawValue), forKey: "printICCIntent")
            scheduleRender()
        }
    }

    init() {
        restorePrintProfile()
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
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let profile = try PrintProfile.load(url: url)
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.profileBookmarkDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyProfilePathDefaultsKey)
            printProfile = profile
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

    /// Start a blank icon in the library and open it. Free, like autosave —
    /// nothing has been invested yet, so there is nothing to gate.
    func newDocument() {
        flushAutosave()
        do {
            let project = try ProjectLibrary.shared.createProject(named: "Untitled")
            openProject(project)
        } catch {
            let message = String(describing: error)
            errorMessage = message
            openErrorMessage = message
        }
    }

    /// Import an external `.icon` into the library, then open the working copy.
    ///
    /// The user's file is only ever read here. Everything after this point —
    /// every edit, every autosave — happens on our own copy.
    func requestOpen(url: URL) {
        flushAutosave()
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        // Reopening the same original — from Open Recent, a second drop, a
        // relaunch — must return to the existing project rather than fork a
        // duplicate and silently strand the earlier edits.
        if let existing = ProjectLibrary.shared.projects.first(where: { $0.originPath == url.path }) {
            RecentDocumentStore.shared.note(url)
            openProject(existing)
            return
        }

        do {
            let imported = try ProjectLibrary.shared.importIcon(from: url)
            RecentDocumentStore.shared.note(url)
            openProject(imported)
            // Say what Pro costs before any work is invested, not after.
            if !StoreManager.shared.isUnlocked { presentPaywall = .importDisclosure }
        } catch {
            let message = String(describing: error)
            errorMessage = message
            openErrorMessage = message
        }
    }

    /// Open (or reopen) a project's working copy from the library.
    func openProject(_ target: LibraryProject) {
        flushAutosave()
        do {
            let doc = try IconDocument.load(bundleURL: ProjectLibrary.shared.bundleURL(for: target))
            project = target
            ProjectLibrary.shared.lastOpenedProjectID = target.id
            document = doc
            errorMessage = nil
            openErrorMessage = nil
            documentWarningsMessage = doc.warnings.isEmpty
                ? nil : doc.warnings.joined(separator: "\n")
            selection = .document
            modifiedShapes = [:]
            modifiedImages = [:]
            isDirty = false
            isShapeEditing = false
            undoStack = []
            redoStack = []
            transactionSnapshot = nil
            render()
        } catch {
            let message = String(describing: error)
            errorMessage = message
            openErrorMessage = message
        }
    }

    /// Restore the last session's project on launch — after a clean quit and
    /// after a crash alike. Never gated, never prompts.
    func restoreLastSession() {
        guard document == nil, let target = ProjectLibrary.shared.projectToRecover else { return }
        openProject(target)
    }

    /// Kept for the window-close and quit paths. Autosave means there is
    /// nothing to lose, so this never blocks and never shows a paywall.
    func confirmDiscardingChanges(action: String, markDiscarded: Bool) -> Bool {
        flushAutosave()
        return true
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

    // MARK: - Autosave (always free)

    private var autosaveTask: Task<Void, Never>?

    /// Debounced autosave into the library working copy. Deliberately silent
    /// and deliberately ungated: the user's work is theirs whether or not they
    /// have bought Pro.
    func scheduleAutosave() {
        guard document != nil, isDirty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            flushAutosave()
        }
    }

    /// Write pending edits to the working copy now. Safe to call on quit, on
    /// window close, and before opening another project.
    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let document, let project, isDirty else { return }
        do {
            try document.save(modifiedShapes: modifiedShapes, modifiedImages: modifiedImages)
            modifiedShapes = [:]
            modifiedImages = [:]
            isDirty = false
            ProjectLibrary.shared.touch(project)
            // Undo history deliberately survives an autosave — unlike an
            // explicit save, an autosave is not a decision the user made.
        } catch {
            // An autosave failure is worth surfacing: it means the library
            // copy is behind what is on screen.
            saveErrorMessage = "Your work could not be autosaved: \(error)"
        }
    }

    // MARK: - Writing out (Pro)

    /// Write the working copy back over the `.icon` the project was imported
    /// from. Callers must have cleared the Pro gate first.
    func saveBackToOrigin() {
        guard let project else { return }
        flushAutosave()
        guard let origin = ProjectLibrary.shared.resolveOrigin(for: project) else {
            saveErrorMessage = String(describing: ProjectLibrary.LibraryError.originUnavailable)
            return
        }
        defer { if origin.secured { origin.url.stopAccessingSecurityScopedResource() } }
        do {
            try ProjectLibrary.shared.copyWorkingCopy(of: project, to: origin.url)
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = String(describing: error)
        }
    }

    /// Write the working copy out as a `.icon` bundle at a chosen location, and
    /// adopt it as the project's origin so later save-backs go there.
    func exportEditableIcon(to url: URL) {
        guard let project else { return }
        flushAutosave()
        do {
            try ProjectLibrary.shared.copyWorkingCopy(of: project, to: url)
            ProjectLibrary.shared.setOrigin(url, for: project)
            self.project = ProjectLibrary.shared.projects.first { $0.id == project.id } ?? project
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = String(describing: error)
        }
    }

    /// Whether a save-back has somewhere to go.
    var hasOrigin: Bool {
        guard let project else { return false }
        return project.originBookmark != nil || project.originPath != nil
    }

    private func restorePrintProfile() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profileBookmarkDefaultsKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                if let profile = try? PrintProfile.load(url: url) {
                    printProfile = profile
                    if stale,
                       let refreshed = try? url.bookmarkData(options: .withSecurityScope,
                                                             includingResourceValuesForKeys: nil,
                                                             relativeTo: nil) {
                        defaults.set(refreshed, forKey: Self.profileBookmarkDefaultsKey)
                    }
                    return
                }
            }
            defaults.removeObject(forKey: Self.profileBookmarkDefaultsKey)
        }

        // One-time migration from pre-sandbox versions that stored a raw path.
        if let path = defaults.string(forKey: Self.legacyProfilePathDefaultsKey) {
            let url = URL(fileURLWithPath: path)
            if let profile = try? PrintProfile.load(url: url),
               let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                printProfile = profile
                defaults.set(bookmark, forKey: Self.profileBookmarkDefaultsKey)
            }
            defaults.removeObject(forKey: Self.legacyProfilePathDefaultsKey)
        }
    }

    private func changed() {
        isDirty = true
        scheduleRender()
    }

    private func reconcileShapeEditingState() {
        isShapeEditing = selectedShape != nil
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

    var canSplitSelectedShapes: Bool {
        let items = selectedDistributionItems()
        guard items.count == selectedLayerIDs.count else { return false }
        return items.contains { item in
            editableShape(group: item.group, layer: item.layer)?.canSplitIntoSubshapes == true
        }
    }

    var canCreateShapesFromHoles: Bool {
        let items = selectedDistributionItems()
        guard items.count == selectedLayerIDs.count else { return false }
        return items.contains { item in
            editableShape(group: item.group, layer: item.layer)?.canCreateShapesFromHoles == true
        }
    }

    var canDistributeSelectedObjects: Bool {
        let items = selectedDistributionItems()
        return items.count >= 3 && items.count == selectedLayerIDs.count
    }

    var canResizeSelectedBounds: Bool {
        guard let snapshot = selectionBoundsSnapshot() else { return false }
        return snapshot.items.count > 1
    }

    var selectedCanvasBounds: CGRect? {
        selectionBoundsSnapshot()?.bounds
    }

    func selectionBoundsSnapshot() -> SelectionBoundsSnapshot? {
        let items = selectedDistributionItems()
        guard !items.isEmpty else { return nil }
        let union = items.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.standardized
        guard !union.isNull, !union.isEmpty else { return nil }
        return SelectionBoundsSnapshot(bounds: union, items: items)
    }

    func setSelectedCanvasBounds(_ target: CGRect) {
        guard let snapshot = selectionBoundsSnapshot() else { return }
        resizeSelectionBounds(snapshot, to: target)
    }

    func translateSelection(_ snapshot: SelectionBoundsSnapshot, by delta: CGPoint) {
        guard delta != .zero else { return }
        let translations = Array(repeating: delta, count: snapshot.items.count)
        applyCanvasTranslations(items: snapshot.items, translations: translations,
                                actionName: "Move Selection")
    }

    func resizeSelectionBounds(_ snapshot: SelectionBoundsSnapshot, to target: CGRect) {
        guard document != nil else { return }
        let source = snapshot.bounds.standardized
        let destination = target.standardized
        guard source.width > 0.0001, source.height > 0.0001,
              !destination.isNull, !destination.isEmpty else { return }

        recordUndo()
        var changedAnything = false
        for item in snapshot.items {
            let mapped = ShapeTransformGeometry.mappedBounds(item.bounds, from: source, to: destination)
            changedAnything = applyCanvasBounds(mapped, to: item) || changedAnything
        }
        if changedAnything {
            changed()
        } else if transactionSnapshot == nil {
            _ = undoStack.popLast()
        }
    }

    private func snapshot() -> EditorSnapshot? {
        guard let document else { return nil }
        return EditorSnapshot(document: document, modifiedShapes: modifiedShapes,
                              modifiedImages: modifiedImages,
                              selection: selection, selectedLayerIDs: selectedLayerIDs,
                              layerSelectionAnchorID: layerSelectionAnchorID,
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
        modifiedImages = snapshot.modifiedImages
        selectedLayerIDs = snapshot.selectedLayerIDs
        layerSelectionAnchorID = snapshot.layerSelectionAnchorID
        synchronizingSelection = true
        selection = snapshot.selection
        synchronizingSelection = false
        isDirty = snapshot.isDirty
        isShapeEditing = selectedShape != nil
        render()
    }

    func withManifest(_ body: (inout IconManifest) -> Void) {
        guard document != nil else { return }
        recordUndo()
        body(&document!.manifest)
        changed()
    }

    /// Mutate a group in place and re-render.
    func withGroup(_ g: Int, _ body: (inout IconGroup) -> Void) {
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

    func group(_ g: Int) -> IconGroup? {
        guard let doc = document, doc.manifest.groups.indices.contains(g) else { return nil }
        return doc.manifest.groups[g]
    }

    func layer(_ g: Int, _ l: Int) -> Layer? {
        guard let grp = group(g), grp.layers.indices.contains(l) else { return nil }
        return grp.layers[l]
    }

    var sidebarSelections: Set<NodeSelection> {
        if case .group = selection { return [selection] }
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

            if NSEvent.modifierFlags.contains(.shift),
               let anchorID = layerSelectionAnchorID ?? currentID {
                let additions = ids.subtracting(selectedLayerIDs)
                let targetID: UUID? = additions.count == 1
                    ? additions.first
                    : (ids.count == 1 ? ids.first : nil)
                if let targetID,
                   let ordered = orderedLayerSelections,
                   let anchorIndex = ordered.firstIndex(where: { $0.id == anchorID }),
                   let targetIndex = ordered.firstIndex(where: { $0.id == targetID }) {
                    let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
                    let range = ordered[bounds]
                    selectedLayerIDs = Set(range.map(\.id))
                    synchronizingSelection = true
                    selection = ordered[targetIndex].selection
                    synchronizingSelection = false
                    layerSelectionAnchorID = anchorID
                    return
                }
            }

            let newlySelectedID = ids.subtracting(selectedLayerIDs).first
            let primary = newlySelectedID.flatMap { id in
                layerSelections.first(where: { $0.1 == id })
            } ?? layerSelections.first(where: { $0.1 == currentID })
                ?? layerSelections.sorted { ($0.2, $0.3) < ($1.2, $1.3) }.first!
            selectedLayerIDs = ids
            synchronizingSelection = true
            selection = primary.0
            synchronizingSelection = false
            if !NSEvent.modifierFlags.contains(.shift) {
                layerSelectionAnchorID = primary.1
            }
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

    private var orderedLayerSelections: [(selection: NodeSelection, id: UUID)]? {
        guard let document else { return nil }
        return document.manifest.groups.enumerated().flatMap { g, group in
            group.layers.enumerated().map { l, layer in
                (NodeSelection.layer(g, l), layer.id)
            }
        }
    }

    // MARK: - Canvas selection

    /// Where a layer currently lives in the manifest.
    func location(ofLayer id: UUID) -> (group: Int, layer: Int)? {
        guard let document else { return nil }
        for (g, group) in document.manifest.groups.enumerated() {
            if let l = group.layers.firstIndex(where: { $0.id == id }) { return (g, l) }
        }
        return nil
    }

    /// The topmost visible layer whose artwork covers `point`, given in
    /// 1024-point icon canvas coordinates. Groups and layers are listed
    /// topmost-first, so plain manifest order is already front-to-back.
    /// `tolerance` widens thin outlines so they stay clickable.
    func layerHitTest(at point: CGPoint, tolerance: CGFloat = 6) -> (group: Int, layer: Int)? {
        guard let document else { return nil }
        for (g, group) in document.manifest.groups.enumerated() where !group.hidden {
            for (l, layer) in group.layers.enumerated() where !layer.hidden {
                let transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                if let shape = document.shapes[layer.imageName] {
                    var applied = transform
                    guard let path = shape.path.copy(using: &applied) else { continue }
                    if path.contains(point, using: .evenOdd) { return (g, l) }
                    let ring = path.copy(strokingWithWidth: max(tolerance, 1) * 2,
                                         lineCap: .round, lineJoin: .round, miterLimit: 10)
                    if ring.contains(point) { return (g, l) }
                } else if document.images[layer.imageName] != nil {
                    let box = CGRect(x: 0, y: 0, width: 1024, height: 1024).applying(transform)
                    if box.contains(point) { return (g, l) }
                }
            }
        }
        return nil
    }

    /// Canvas click: select the layer under `point`. `extend` (⇧) adds to the
    /// selection, `toggle` (⌘) flips just that layer, and a plain click on
    /// empty canvas clears the selection. Returns whether a layer was hit.
    @discardableResult
    func selectLayer(at point: CGPoint, tolerance: CGFloat = 6,
                     extend: Bool = false, toggle: Bool = false) -> Bool {
        guard let hit = layerHitTest(at: point, tolerance: tolerance),
              let item = layer(hit.group, hit.layer) else {
            if !extend && !toggle { selection = .document }
            return false
        }
        selectLayer(id: item.id, extend: extend, toggle: toggle)
        return true
    }

    func selectLayer(id: UUID, extend: Bool = false, toggle: Bool = false) {
        guard let place = location(ofLayer: id) else { return }
        var ids = (extend || toggle) ? selectedLayerIDs : []
        if toggle, ids.contains(id) {
            ids.remove(id)
            selectedLayerIDs = ids
            if let remaining = ids.first, let fallback = location(ofLayer: remaining) {
                setPrimarySelection(.layer(fallback.group, fallback.layer))
            } else {
                selection = .document
            }
            return
        }
        ids.insert(id)
        selectedLayerIDs = ids
        layerSelectionAnchorID = id
        setPrimarySelection(.layer(place.group, place.layer))
    }

    /// Change the primary selection without disturbing `selectedLayerIDs`.
    private func setPrimarySelection(_ value: NodeSelection) {
        synchronizingSelection = true
        selection = value
        synchronizingSelection = false
    }

    var primarySelectedLayerLocation: (group: Int, layer: Int)? {
        switch selection {
        case .layer(let g, let l):
            return layer(g, l) == nil ? nil : (g, l)
        case .group(let g):
            return group(g)?.layers.isEmpty == false ? (g, 0) : nil
        case .document:
            return nil
        }
    }

    var selectedShape: EditableShape? {
        guard let location = primarySelectedLayerLocation,
              let layer = layer(location.group, location.layer),
              layer.imageName.lowercased().hasSuffix(".svg") else { return nil }
        if let modified = modifiedShapes[layer.imageName] { return modified }
        guard let shape = document?.shapes[layer.imageName] else { return nil }
        return EditableShape(shape: shape)
    }

    func updateSelectedShape(_ shape: EditableShape) {
        guard let location = primarySelectedLayerLocation,
              let layer = layer(location.group, location.layer) else { return }
        recordUndo()
        modifiedShapes[layer.imageName] = shape
        document?.shapes[layer.imageName] = shape.svgShape
        changed()
    }

    func mutateSelectedShape(_ mutate: (inout EditableShape) -> Void) {
        guard var shape = selectedShape else { return }
        mutate(&shape)
        updateSelectedShape(shape)
    }

    var canCopySelection: Bool { document != nil && !selectedLayerIDs.isEmpty }

    var canPasteLayers: Bool {
        document != nil && clipboardPayload() != nil
    }

    var canDuplicateSelection: Bool { canCopySelection }

    func copySelection() {
        guard let payload = clipboardPayloadForSelection(),
              let data = try? JSONEncoder().encode(payload) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.layerPasteboardType)
    }

    func pasteLayers() {
        guard document != nil, let payload = clipboardPayload() else { return }
        insertLayers(from: payload)
    }

    func duplicateSelection() {
        guard let payload = clipboardPayloadForSelection() else { return }
        insertLayers(from: payload)
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
            document!.manifest.groups.append(IconGroup())
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
        document!.shapes[assetName] = shape.svgShape
        modifiedShapes[assetName] = shape
        selection = .layer(targetGroup, 0)
        isShapeEditing = true
        changed()
    }

    func addPenPath(at point: CGPoint) {
        let path = VectorPath(subpaths: [VectorSubpath(nodes: [VectorNode(position: point)])])
        addEditableShape(EditableShape(vectorPath: path, isFilled: false), name: "Path")
    }

    private func addEditableShape(_ shape: EditableShape, name: String) {
        guard document != nil else { return }
        recordUndo()
        if document!.manifest.groups.isEmpty { document!.manifest.groups.append(IconGroup()) }
        let groupIndex = targetGroupIndex()
        let assetName = uniqueAssetName(base: name, preferredExtension: "svg")
        let layer = Layer(name: name, imageName: assetName,
                          fill: Specialized(base: .automaticGradient(
                            ColorSpec(space: .srgb, r: 0.22, g: 0.55, b: 1, a: 1))))
        document!.manifest.groups[groupIndex].layers.insert(layer, at: 0)
        store(shape, assetName: assetName)
        selection = .layer(groupIndex, 0)
        isShapeEditing = true
        changed()
    }

    func addGroup() {
        guard document != nil else { return }
        recordUndo()
        document!.manifest.groups.insert(IconGroup(), at: 0)
        selection = .group(0)
        changed()
    }

    /// Add an empty vector layer to the selected group and arm the pen tool so
    /// the next canvas click starts drawing into it.
    func addEmptyLayer() {
        guard document != nil else { return }
        recordUndo()
        if document!.manifest.groups.isEmpty { document!.manifest.groups.append(IconGroup()) }
        let groupIndex = targetGroupIndex()
        let name = uniqueLayerName()
        let assetName = uniqueAssetName(base: name, preferredExtension: "svg")
        let layer = Layer(name: name, imageName: assetName,
                          fill: Specialized(base: .automaticGradient(
                            ColorSpec(space: .srgb, r: 0.22, g: 0.55, b: 1, a: 1))))
        document!.manifest.groups[groupIndex].layers.insert(layer, at: 0)
        store(EditableShape(vectorPath: VectorPath(), isFilled: true), assetName: assetName)
        selection = .layer(groupIndex, 0)
        isShapeEditing = true
        canvasTool = .pen
        changed()
    }

    private func uniqueLayerName() -> String {
        let existing = Set(document?.manifest.groups.flatMap(\.layers).map(\.name) ?? [])
        var counter = existing.count + 1
        while existing.contains("Layer \(counter)") { counter += 1 }
        return "Layer \(counter)"
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
                document!.images.removeValue(forKey: name)
                modifiedShapes.removeValue(forKey: name)
                modifiedImages.removeValue(forKey: name)
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
                modifiedImages.removeValue(forKey: name)
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

    func moveGroup(from sourceIndex: Int, before targetIndex: Int) {
        guard document != nil,
              document!.manifest.groups.indices.contains(sourceIndex) else { return }
        let clampedTarget = max(0, min(targetIndex, document!.manifest.groups.count))
        var effectiveTarget = clampedTarget
        if sourceIndex < effectiveTarget { effectiveTarget -= 1 }
        guard sourceIndex != effectiveTarget else { return }

        recordUndo()
        let group = document!.manifest.groups.remove(at: sourceIndex)
        document!.manifest.groups.insert(group, at: effectiveTarget)
        selection = .group(effectiveTarget)
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
        importSVG(from: url)
    }

    /// Import SVG artwork as a new layer at the front of the target group.
    /// Shared by the import panel and by dropping a file onto the window.
    @discardableResult
    func importSVG(from url: URL) -> Bool {
        guard document != nil else { return false }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let imported = SVGShape.load(url: url) else {
            saveErrorMessage = "No vector geometry was found in \(url.lastPathComponent)."
            return false
        }

        var transform = normalizationTransform(for: imported.viewBox)
        guard let path = imported.path.copy(using: &transform) else { return false }
        let sourcePieces = imported.splitIntoSubshapes()
        let splitComponents: [VectorPath]? = sourcePieces.count > 1
            ? sourcePieces.compactMap { piece in
                var componentTransform = transform
                return piece.path.copy(using: &componentTransform).map(VectorPath.init(cgPath:))
            }
            : nil
        let editable = EditableShape(shape: SVGShape(path: path),
                                     splitComponents: splitComponents)
        let groupIndex = targetGroupIndex()
        let base = url.deletingPathExtension().lastPathComponent
        let assetName = uniqueAssetName(base: base, preferredExtension: "svg")
        let newLayer = Layer(name: base, imageName: assetName,
                             fill: Specialized(base: .automaticGradient(
                                ColorSpec(space: .srgb, r: 0.22, g: 0.55, b: 1, a: 1))))
        recordUndo()
        if document!.manifest.groups.isEmpty { document!.manifest.groups.append(IconGroup()) }
        document!.manifest.groups[groupIndex].layers.insert(newLayer, at: 0)
        document!.shapes[assetName] = editable.svgShape
        modifiedShapes[assetName] = editable
        selection = .layer(groupIndex, 0)
        isShapeEditing = true
        changed()
        return true
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
        resultLayer.imageName = uniqueAssetName(base: operation.rawValue, preferredExtension: "svg")
        let insertion = min(base.l, document!.manifest.groups[resultGroup].layers.count)
        document!.manifest.groups[resultGroup].layers.insert(resultLayer, at: insertion)
        document!.shapes[resultLayer.imageName] = editable.svgShape
        modifiedShapes[resultLayer.imageName] = editable
        selectedLayerIDs = [resultLayer.id]
        synchronizingSelection = true
        selection = .layer(resultGroup, insertion)
        synchronizingSelection = false
        isShapeEditing = true
        changed()
    }

    func distributeSelectedObjects(_ axis: ShapeDistributionAxis) {
        let items = selectedDistributionItems()
        guard items.count >= 3, items.count == selectedLayerIDs.count else { return }
        let translations = ShapeDistribution.translations(
            for: items.map(\.bounds), along: axis)
        guard translations.contains(where: { $0 != .zero }) else { return }

        recordUndo()
        for (item, translation) in zip(items, translations) where translation != .zero {
            let groupScale = document!.manifest.groups[item.group].position.scale
            guard abs(groupScale) > 0.000_001 else { continue }
            var position = document!.manifest.groups[item.group].layers[item.layer].position
            var values = position.translation
            while values.count < 2 { values.append(0) }
            values[0] += Double(translation.x) / groupScale
            values[1] += Double(translation.y) / groupScale
            position.translation = values
            document!.manifest.groups[item.group].layers[item.layer].position = position
        }
        changed()
    }

    func performSelectionOperation(_ operation: ShapeSelectionOperation) {
        let items = selectedDistributionItems()
        guard !items.isEmpty, items.count == selectedLayerIDs.count, document != nil else { return }

        switch operation {
        case .align(let alignment, let reference):
            let keyIndex: Int? = {
                guard reference == .keyObject,
                      case .layer(let g, let l) = selection else { return nil }
                return items.firstIndex { $0.group == g && $0.layer == l }
            }()
            let translations = ShapeArrangement.alignmentTranslations(
                for: items.map(\.bounds), alignment: alignment,
                referenceBounds: reference == .canvas
                    ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : nil,
                keyObjectIndex: keyIndex)
            applyCanvasTranslations(items: items, translations: translations,
                                    actionName: alignment.displayName)
        case .distribute(let axis, let mode, let exactGap):
            let translations = ShapeArrangement.distributionTranslations(
                for: items.map(\.bounds), along: axis, mode: mode, exactGap: exactGap)
            applyCanvasTranslations(items: items, translations: translations,
                                    actionName: operation.actionName)
        default:
            performShapeGeometryOperation(operation, items: items)
        }
    }

    private func performShapeGeometryOperation(
        _ operation: ShapeSelectionOperation,
        items: [SelectionCanvasItem]) {
        guard document != nil else { return }
        recordUndo()
        var changedGeometry = false
        var replacementIDs: Set<UUID>?

        switch operation {
        case .outlineStroke, .offset, .roundCorners, .simplify, .fillHoles,
             .releaseMask, .convertTextToOutlines, .setNodeType,
             .removeNode, .splitPath, .closePath, .joinPaths:
            var processedAssets: Set<String> = []
            for item in items {
                let layer = document!.manifest.groups[item.group].layers[item.layer]
                guard processedAssets.insert(layer.imageName).inserted,
                      var editable = editableShape(group: item.group, layer: item.layer) else { continue }
                switch operation {
                case .outlineStroke: editable = editable.convertedToOutlines()
                case .offset(let distance): editable = editable.offset(by: distance)
                case .roundCorners(let radius): editable = editable.roundingCorners(radius: radius)
                case .simplify(let tolerance): editable = editable.simplifying(tolerance: tolerance)
                case .fillHoles: editable = editable.fillingHoles()
                case .releaseMask: editable = editable.releasingMask()
                case .convertTextToOutlines:
                    guard editable.kind == .text else { continue }
                    editable = editable.convertedToOutlines()
                case .setNodeType(let type):
                    guard let handle = selectedPathHandle else { continue }
                    editable.setPathNodeType(type, at: handle)
                case .removeNode:
                    guard let handle = selectedPathHandle else { continue }
                    guard editable.removePathNode(at: handle) else { continue }
                    selectedPathHandle = nil
                case .splitPath:
                    guard let handle = selectedPathHandle else { continue }
                    editable.splitPath(at: handle)
                case .closePath:
                    guard let handle = selectedPathHandle
                            ?? editable.pathHandles.first(where: { $0.0.component == .anchor })?.0 else { continue }
                    editable.closePath(containing: handle)
                case .joinPaths:
                    guard editable.joinOpenPaths() else { continue }
                default: break
                }
                store(editable, assetName: layer.imageName)
                changedGeometry = true
            }
        case .splitIntoShapes:
            var newIDs: Set<UUID> = []
            for item in items.sorted(by: {
                $0.group == $1.group ? $0.layer > $1.layer : $0.group > $1.group
            }) {
                let sourceLayer = document!.manifest.groups[item.group].layers[item.layer]
                guard let editable = editableShape(group: item.group, layer: item.layer) else { continue }
                let pieces = editable.splitIntoSubshapes()
                guard pieces.count > 1 else {
                    newIDs.insert(sourceLayer.id)
                    continue
                }

                document!.manifest.groups[item.group].layers.remove(at: item.layer)
                var layers: [Layer] = []
                for (offset, piece) in pieces.enumerated() {
                    let assetName = uniqueAssetName(base: "\(sourceLayer.name)-\(offset + 1)",
                                                    preferredExtension: "svg")
                    let layer = Layer(name: "\(sourceLayer.name) \(offset + 1)",
                                      imageName: assetName,
                                      position: sourceLayer.position,
                                      hidden: sourceLayer.hidden,
                                      fill: sourceLayer.fill,
                                      opacity: sourceLayer.opacity,
                                      glass: sourceLayer.glass,
                                      blendMode: sourceLayer.blendMode)
                    layers.append(layer)
                    store(piece, assetName: assetName)
                    newIDs.insert(layer.id)
                }
                document!.manifest.groups[item.group].layers.insert(contentsOf: layers, at: item.layer)
                if !document!.manifest.groups.flatMap(\.layers)
                    .contains(where: { $0.imageName == sourceLayer.imageName }) {
                    document!.shapes.removeValue(forKey: sourceLayer.imageName)
                    modifiedShapes.removeValue(forKey: sourceLayer.imageName)
                }
                changedGeometry = true
            }
            replacementIDs = newIDs
        case .createShapesFromHoles:
            var newIDs: Set<UUID> = []
            for item in items.sorted(by: {
                $0.group == $1.group ? $0.layer > $1.layer : $0.group > $1.group
            }) {
                let sourceLayer = document!.manifest.groups[item.group].layers[item.layer]
                guard let editable = editableShape(group: item.group, layer: item.layer) else { continue }
                let holes = editable.holeSubshapes()
                guard !holes.isEmpty else { continue }

                var layers: [Layer] = []
                for (offset, hole) in holes.enumerated() {
                    let assetName = uniqueAssetName(
                        base: "\(sourceLayer.name)-hole-\(offset + 1)",
                        preferredExtension: "svg")
                    let layer = Layer(name: "\(sourceLayer.name) Hole \(offset + 1)",
                                      imageName: assetName,
                                      position: sourceLayer.position,
                                      hidden: sourceLayer.hidden,
                                      fill: sourceLayer.fill,
                                      opacity: sourceLayer.opacity,
                                      glass: sourceLayer.glass,
                                      blendMode: sourceLayer.blendMode)
                    layers.append(layer)
                    store(hole, assetName: assetName)
                    newIDs.insert(layer.id)
                }
                document!.manifest.groups[item.group].layers.insert(contentsOf: layers, at: item.layer)
                changedGeometry = true
            }
            replacementIDs = newIDs
        case .makeMask(let inverted):
            guard items.count >= 2, let maskItem = items.last,
                  let maskShape = editableShape(group: maskItem.group, layer: maskItem.layer) else { break }
            let maskLayer = document!.manifest.groups[maskItem.group].layers[maskItem.layer]
            var maskTransform = IconRenderer.layerCanvasTransform(
                layer: maskLayer, group: document!.manifest.groups[maskItem.group])
            guard let finalMask = maskShape.path.copy(using: &maskTransform) else { break }
            let targets = items.dropLast()
            let targetIDs = Set(targets.map {
                document!.manifest.groups[$0.group].layers[$0.layer].id
            })
            for item in targets {
                let layer = document!.manifest.groups[item.group].layers[item.layer]
                guard let editable = editableShape(group: item.group, layer: item.layer) else { continue }
                var inverse = IconRenderer.layerCanvasTransform(
                    layer: layer, group: document!.manifest.groups[item.group]).inverted()
                guard let localMask = finalMask.copy(using: &inverse) else { continue }
                store(editable.applyingMask(localMask, inverted: inverted), assetName: layer.imageName)
            }
            let maskID = maskLayer.id
            for groupIndex in document!.manifest.groups.indices {
                document!.manifest.groups[groupIndex].layers.removeAll { $0.id == maskID }
            }
            replacementIDs = targetIDs
            changedGeometry = true
        case .attachTextToPath:
            guard let pathItem = items.first(where: {
                editableShape(group: $0.group, layer: $0.layer)?.kind == .path
            }), let source = editableShape(group: pathItem.group, layer: pathItem.layer) else { break }
            let sourceLayer = document!.manifest.groups[pathItem.group].layers[pathItem.layer]
            var sourceTransform = IconRenderer.layerCanvasTransform(
                layer: sourceLayer, group: document!.manifest.groups[pathItem.group])
            guard let finalPath = source.path.copy(using: &sourceTransform) else { break }
            for item in items {
                let layer = document!.manifest.groups[item.group].layers[item.layer]
                guard let text = editableShape(group: item.group, layer: item.layer), text.kind == .text else { continue }
                var inverse = IconRenderer.layerCanvasTransform(
                    layer: layer, group: document!.manifest.groups[item.group]).inverted()
                guard let localPath = finalPath.copy(using: &inverse) else { continue }
                store(text.attachingText(to: localPath), assetName: layer.imageName)
                changedGeometry = true
            }
        case .repeatTransform(let transform):
            var newIDs: Set<UUID> = []
            for step in 1...transform.copies {
                for item in items {
                    let sourceLayer = document!.manifest.groups[item.group].layers[item.layer]
                    guard let editable = editableShape(group: item.group, layer: item.layer) else { continue }
                    let assetName = uniqueAssetName(base: sourceLayer.name + "-copy",
                                                    preferredExtension: "svg")
                    let copyLayer = duplicatedLayer(sourceLayer, imageName: assetName)
                    document!.manifest.groups[item.group].layers.insert(copyLayer, at: 0)
                    let repeated = editable.repeated(step: step, transform: transform)
                    store(repeated, assetName: assetName)
                    newIDs.insert(copyLayer.id)
                }
            }
            replacementIDs = newIDs
            changedGeometry = !newIDs.isEmpty
        case .mirror(let axis):
            let union = items.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            let finalPosition = axis == .horizontal ? union.midY : union.midX
            for item in items {
                let layer = document!.manifest.groups[item.group].layers[item.layer]
                guard let editable = editableShape(group: item.group, layer: item.layer) else { continue }
                let inverse = IconRenderer.layerCanvasTransform(
                    layer: layer, group: document!.manifest.groups[item.group]).inverted()
                let probe = axis == .horizontal
                    ? CGPoint(x: 0, y: finalPosition).applying(inverse).y
                    : CGPoint(x: finalPosition, y: 0).applying(inverse).x
                store(editable.mirrored(across: axis, position: probe), assetName: layer.imageName)
                changedGeometry = true
            }
        case .align, .distribute:
            break
        }

        guard changedGeometry else {
            _ = undoStack.popLast()
            return
        }
        if let replacementIDs {
            selectedLayerIDs = replacementIDs
            synchronizePrimarySelection(to: replacementIDs.first)
        }
        changed()
    }

    private func editableShape(group: Int, layer: Int) -> EditableShape? {
        guard let item = self.layer(group, layer) else { return nil }
        if let modified = modifiedShapes[item.imageName] { return modified }
        guard let shape = document?.shapes[item.imageName] else { return nil }
        return EditableShape(shape: shape)
    }

    private func store(_ shape: EditableShape, assetName: String) {
        modifiedShapes[assetName] = shape
        document!.shapes[assetName] = shape.svgShape
    }

    private func clipboardPayloadForSelection() -> LayerClipboardPayload? {
        guard let document, !selectedLayerIDs.isEmpty else { return nil }
        let layers = document.manifest.groups.flatMap(\.layers).filter { selectedLayerIDs.contains($0.id) }
        guard !layers.isEmpty else { return nil }
        let items = layers.compactMap { item -> LayerClipboardItem? in
            if let shape = copiedShape(named: item.imageName) {
                return LayerClipboardItem(layer: item, asset: .svg(shape.svgData))
            }
            guard let image = document.images[item.imageName],
                  let data = pngData(from: image) else { return nil }
            return LayerClipboardItem(layer: item, asset: .rasterPNG(data))
        }
        return items.isEmpty ? nil : LayerClipboardPayload(layers: items)
    }

    private func clipboardPayload() -> LayerClipboardPayload? {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: Self.layerPasteboardType) else { return nil }
        return try? JSONDecoder().decode(LayerClipboardPayload.self, from: data)
    }

    private func insertLayers(from payload: LayerClipboardPayload) {
        guard document != nil, !payload.layers.isEmpty else { return }
        recordUndo()
        if document!.manifest.groups.isEmpty { document!.manifest.groups.append(IconGroup()) }
        let destination = pasteDestination()
        var insertionIndex = destination.index
        var insertedIDs: [UUID] = []
        for item in payload.layers {
            guard let inserted = materializeLayer(from: item) else { continue }
            document!.manifest.groups[destination.group].layers.insert(inserted, at: insertionIndex)
            insertedIDs.append(inserted.id)
            insertionIndex += 1
        }
        guard !insertedIDs.isEmpty else {
            _ = undoStack.popLast()
            return
        }
        selectedLayerIDs = Set(insertedIDs)
        synchronizePrimarySelection(to: insertedIDs.first)
        isShapeEditing = selectedShape != nil
        changed()
    }

    private func materializeLayer(from item: LayerClipboardItem) -> Layer? {
        guard document != nil else { return nil }
        let baseName = item.layer.name.isEmpty
            ? URL(fileURLWithPath: item.layer.imageName).deletingPathExtension().lastPathComponent
            : item.layer.name
        switch item.asset {
        case .svg(let data):
            guard let shape = SVGShape.parse(data: data) else { return nil }
            let assetName = uniqueAssetName(base: baseName, preferredExtension: "svg")
            let editable = EditableShape(shape: shape)
            modifiedShapes[assetName] = editable
            document!.shapes[assetName] = editable.svgShape
            var layer = item.layer
            layer.name = copiedLayerName(item.layer)
            layer.imageName = assetName
            return layer
        case .rasterPNG(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let assetName = uniqueAssetName(base: baseName, preferredExtension: "png")
            modifiedImages[assetName] = image
            document!.images[assetName] = image
            var layer = item.layer
            layer.name = copiedLayerName(item.layer)
            layer.imageName = assetName
            return layer
        }
    }

    private func copiedShape(named imageName: String) -> EditableShape? {
        if let modified = modifiedShapes[imageName] { return modified }
        guard let shape = document?.shapes[imageName] else { return nil }
        return EditableShape(shape: shape)
    }

    private func copiedLayerName(_ layer: Layer) -> String {
        let source = layer.name.isEmpty
            ? URL(fileURLWithPath: layer.imageName).deletingPathExtension().lastPathComponent
            : layer.name
        return source.hasSuffix(" copy") ? source : source + " copy"
    }

    private func pasteDestination() -> (group: Int, index: Int) {
        guard let document else { return (0, 0) }
        if document.manifest.groups.isEmpty { return (0, 0) }
        switch selection {
        case .layer(let group, let layer):
            let g = min(group, document.manifest.groups.count - 1)
            let l = min(layer, document.manifest.groups[g].layers.count)
            return (g, l)
        case .group(let group):
            let g = min(group, document.manifest.groups.count - 1)
            return (g, 0)
        case .document:
            return (0, 0)
        }
    }

    private func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func applyCanvasTranslations(
        items: [SelectionCanvasItem],
        translations: [CGPoint], actionName: String) {
        guard translations.contains(where: { $0 != .zero }) else { return }
        recordUndo()
        for (item, translation) in zip(items, translations) where translation != .zero {
            let groupScale = document!.manifest.groups[item.group].position.scale
            guard abs(groupScale) > 0.000_001 else { continue }
            var position = document!.manifest.groups[item.group].layers[item.layer].position
            var values = position.translation
            while values.count < 2 { values.append(0) }
            values[0] += Double(translation.x) / groupScale
            values[1] += Double(translation.y) / groupScale
            position.translation = values
            document!.manifest.groups[item.group].layers[item.layer].position = position
        }
        changed()
    }

    private func applyCanvasBounds(_ finalBounds: CGRect, to item: SelectionCanvasItem) -> Bool {
        guard let layer = layer(item.group, item.layer),
              let group = group(item.group),
              !finalBounds.isNull, !finalBounds.isEmpty else { return false }

        if var editable = editableShape(group: item.group, layer: item.layer) {
            let inverse = IconRenderer.layerCanvasTransform(layer: layer, group: group).inverted()
            let localBounds = finalBounds.applying(inverse).standardized
            guard !localBounds.isNull, !localBounds.isEmpty else { return false }
            editable.setBounds(localBounds)
            store(editable, assetName: layer.imageName)
            return true
        }

        guard document?.images[layer.imageName] != nil else { return false }
        let groupScale = group.position.scale
        guard abs(groupScale) > 0.000_001 else { return false }

        let center = CGPoint(x: finalBounds.midX, y: finalBounds.midY)
        let averageSide = max(2, (finalBounds.width + finalBounds.height) / 2)
        var position = layer.position
        position.scale = Double(averageSide / (1024 * abs(groupScale)))
        position.translation = [
            Double((center.x - 512 - group.position.tx) / groupScale),
            Double((center.y - 512 - group.position.ty) / groupScale)
        ]
        document!.manifest.groups[item.group].layers[item.layer].position = position
        return true
    }

    private func duplicatedLayer(_ source: Layer, imageName: String) -> Layer {
        Layer(name: source.name + " copy", imageName: imageName,
              position: source.position, hidden: source.hidden, fill: source.fill,
              opacity: source.opacity, glass: source.glass, blendMode: source.blendMode)
    }

    private func synchronizePrimarySelection(to id: UUID?) {
        guard let id, let document else { return }
        for (g, group) in document.manifest.groups.enumerated() {
            if let l = group.layers.firstIndex(where: { $0.id == id }) {
                synchronizingSelection = true
                selection = .layer(g, l)
                synchronizingSelection = false
                return
            }
        }
    }

    private func selectedDistributionItems() -> [SelectionCanvasItem] {
        guard let document, !selectedLayerIDs.isEmpty else { return [] }
        var items: [SelectionCanvasItem] = []
        for (groupIndex, group) in document.manifest.groups.enumerated() {
            guard abs(group.position.scale) > 0.000_001 else { continue }
            for (layerIndex, layer) in group.layers.enumerated()
            where selectedLayerIDs.contains(layer.id) {
                let transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                let bounds: CGRect?
                if let shape = document.shapes[layer.imageName] {
                    var applied = transform
                    bounds = shape.path.copy(using: &applied)?.boundingBoxOfPath
                } else if document.images[layer.imageName] != nil {
                    bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
                        .applying(transform)
                } else {
                    bounds = nil
                }
                if let bounds, !bounds.isNull {
                    items.append(SelectionCanvasItem(group: groupIndex,
                                                     layer: layerIndex,
                                                     bounds: bounds))
                }
            }
        }
        return items
    }

    private func targetGroupIndex() -> Int {
        guard let document, !document.manifest.groups.isEmpty else { return 0 }
        switch selection {
        case .group(let g), .layer(let g, _): return min(g, document.manifest.groups.count - 1)
        case .document: return 0
        }
    }

    private func uniqueAssetName(base: String, preferredExtension: String) -> String {
        let cleaned = base.lowercased().replacingOccurrences(
            of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = cleaned.isEmpty ? "shape" : cleaned
        let existing = Set(document?.manifest.groups.flatMap(\.layers).map(\.imageName) ?? [])
        let ext = preferredExtension.lowercased()
        var name = "\(stem).\(ext)"
        var counter = 2
        while existing.contains(name) || document?.shapes[name] != nil || document?.images[name] != nil {
            name = "\(stem)-\(counter).\(ext)"; counter += 1
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
            // Applying a lighting recipe must not change the document's shape.
            self.recipe = self.recipe.applyingLighting(of: recipe)
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
