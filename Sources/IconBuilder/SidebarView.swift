import SwiftUI
import UniformTypeIdentifiers

/// Document → groups → layers tree, topmost-first (Icon Composer sidebar order).
/// Rendered as one flat ForEach with globally unique row ids — nested ForEach
/// with per-group integer ids makes the AppKit-backed List recycle rows across
/// groups.
struct SidebarPane: View {
    @Bindable var model: AppModel
    @State private var draggedLayerID: UUID?
    @State private var dropLocation: IconLayerDropLocation?
    @State private var draggedGroupIndex: Int?
    @State private var groupDropLocation: IconGroupDropLocation?

    /// Fixed so the drop delegate can split a row into an above/below half.
    private static let rowHeight: CGFloat = 32

    private struct Row: Identifiable {
        enum Kind {
            case document(String)
            case group(Int)
            case layer(g: Int, l: Int, layer: Layer)
        }
        let id: String
        let kind: Kind
        let selection: NodeSelection
    }

    private var rows: [Row] {
        guard let doc = model.document else { return [] }
        var out: [Row] = [Row(id: "doc", kind: .document(doc.displayName), selection: .document)]
        for (g, group) in doc.manifest.groups.enumerated() {
            out.append(Row(id: "g\(g)", kind: .group(g), selection: .group(g)))
            for (l, layer) in group.layers.enumerated() {
                out.append(Row(id: "g\(g)l\(l)", kind: .layer(g: g, l: l, layer: layer),
                               selection: .layer(g, l)))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("New Layer", systemImage: "square.stack.3d.up.badge.automatic") {
                    model.addEmptyLayer()
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .disabled(model.document == nil)
                .accessibilityLabel("Add empty layer")
                .help("Add an empty vector layer to the selected group and start drawing.")
                Button("Add Group", systemImage: "folder.badge.plus") {
                    model.addGroup()
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .disabled(model.document == nil)
                .accessibilityLabel("Add group")
                .help("Add a new group at the top of the icon.")
                Spacer()
                Text("Top renders in front")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)

            Divider()

            // A plain scrolling stack rather than a `List`: on macOS the
            // AppKit-backed list intercepts row drags for its own purposes and
            // `onDrag` never fires, which is why reordering has to be built the
            // way SymbolBuilder's layer pane does it.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.document == nil {
                        Text("No document")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(rows) { row in
                            rowView(row)
                                .contentShape(Rectangle())
                                .background(rowBackground(row))
                                .onTapGesture { select(row) }
                                .contextMenu {
                                    switch row.selection {
                                    case .document:
                                        Button("Add Group", systemImage: "folder.badge.plus") {
                                            model.addGroup()
                                        }
                                    case .group:
                                        Button("New Empty Layer", systemImage: "square.stack.3d.up.badge.automatic") {
                                            model.selection = row.selection
                                            model.addEmptyLayer()
                                        }
                                        Menu("Add Shape") {
                                            ForEach(IconShapeKind.allCases.filter { $0 != .path }) { kind in
                                                Button(kind.displayName) {
                                                    model.selection = row.selection
                                                    model.addShape(kind)
                                                }
                                            }
                                        }
                                        Divider()
                                        Button("Delete Group", systemImage: "trash", role: .destructive) {
                                            model.selection = row.selection
                                            model.deleteSelection()
                                        }
                                    case .layer:
                                        Button("Duplicate Layer", systemImage: "plus.square.on.square") {
                                            model.selection = row.selection
                                            model.duplicateSelection()
                                        }
                                        Button("Delete Layer", systemImage: "trash", role: .destructive) {
                                            model.selection = row.selection
                                            model.deleteSelection()
                                        }
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Document layers")
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { model.deleteSelection() }
        }
    }

    @ViewBuilder
    private func rowBackground(_ row: Row) -> some View {
        if model.sidebarSelections.contains(row.selection) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.25))
                .padding(.horizontal, 4)
        }
    }

    /// Reproduces the list's selection behaviour: plain click replaces, ⌘
    /// toggles one row, ⇧ extends. `setSidebarSelections` reads the modifier
    /// flags itself to work out the anchored range.
    private func select(_ row: Row) {
        let modifiers = NSEvent.modifierFlags
        var values: Set<NodeSelection> = Set(model.sidebarSelections.filter {
            if case .layer = $0 { return true }
            return false
        })
        if case .layer = row.selection, modifiers.contains(.command) {
            if values.contains(row.selection) {
                values.remove(row.selection)
            } else {
                values.insert(row.selection)
            }
        } else if case .layer = row.selection, modifiers.contains(.shift) {
            values.insert(row.selection)
        } else {
            values = [row.selection]
        }
        model.setSidebarSelections(values)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case .document(let name):
            Label(name, systemImage: "app.dashed")
                .padding(.leading, 8)
                .frame(height: Self.rowHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    if groupDropLocation?.anchor == .document { insertionLine }
                }
                .onDrop(of: [.iconBuilderGroup], delegate: IconGroupDropDelegate(
                    insertionIndex: 0,
                    anchor: .document,
                    rowHeight: Self.rowHeight,
                    draggedGroupIndex: $draggedGroupIndex,
                    dropLocation: $groupDropLocation,
                    onMove: moveGroup))
        case .group(let g):
            HStack(spacing: 6) {
                VisibilityButton(itemName: "Group \(g + 1)",
                                 isVisible: model.group(g)?.hidden != true) {
                    model.withGroup(g) { $0.hidden.toggle() }
                }
                Label("Group \(g + 1)", systemImage: "folder")
                Spacer()
            }
            .padding(.leading, 8)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(model.group(g)?.hidden == true ? 0.65 : 1)
            .overlay(alignment: .top) {
                if groupDropLocation?.anchor == .group(index: g),
                   groupDropLocation?.edge == .above { insertionLine }
            }
            .overlay(alignment: .bottom) {
                if dropLocation?.groupHeader == g { insertionLine }
                if groupDropLocation?.anchor == .group(index: g),
                   groupDropLocation?.edge == .below { insertionLine }
            }
            .onDrag {
                draggedGroupIndex = g
                return groupProvider(g)
            }
            .onDrop(of: [.iconBuilderGroup], delegate: IconGroupDropDelegate(
                insertionIndex: g,
                anchor: .group(index: g),
                rowHeight: Self.rowHeight,
                draggedGroupIndex: $draggedGroupIndex,
                dropLocation: $groupDropLocation,
                onMove: moveGroup))
            .onDrop(of: [.iconBuilderLayer], delegate: IconLayerDropDelegate(
                group: g,
                insertionIndex: 0,
                groupHeader: g,
                layerID: nil,
                rowHeight: 1,
                draggedLayerID: $draggedLayerID,
                dropLocation: $dropLocation,
                onMove: moveLayer))
        case .layer(let g, let l, let layer):
            HStack(spacing: 6) {
                VisibilityButton(itemName: layer.name.isEmpty ? layer.imageName : layer.name,
                                 isVisible: !layer.hidden) {
                    model.withLayer(g, l) { $0.hidden.toggle() }
                }
                LayerThumb(model: model, g: g, l: l)
                Text(layer.name.isEmpty ? layer.imageName : layer.name)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 24)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(layer.hidden || model.group(g)?.hidden == true ? 0.65 : 1)
            .overlay(alignment: .top) {
                if dropLocation?.layerID == layer.id,
                   dropLocation?.edge == .above { insertionLine }
            }
            .overlay(alignment: .bottom) {
                if dropLocation?.layerID == layer.id,
                   dropLocation?.edge == .below { insertionLine }
            }
            .onDrag {
                draggedLayerID = layer.id
                return layerProvider(layer.id)
            }
            .onDrop(of: [.iconBuilderLayer], delegate: IconLayerDropDelegate(
                group: g,
                insertionIndex: l,
                groupHeader: nil,
                layerID: layer.id,
                rowHeight: Self.rowHeight,
                draggedLayerID: $draggedLayerID,
                dropLocation: $dropLocation,
                onMove: moveLayer))
        }
    }

    private func layerProvider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.iconBuilderLayer.identifier,
                                            visibility: .all) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    private func groupProvider(_ index: Int) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.iconBuilderGroup.identifier,
                                            visibility: .all) { completion in
            completion(Data(String(index).utf8), nil)
            return nil
        }
        return provider
    }

    private func moveLayer(_ id: UUID, to group: Int, at index: Int) {
        model.moveLayer(id: id, toGroup: group, before: index)
        draggedLayerID = nil
        dropLocation = nil
    }

    private func moveGroup(_ index: Int, before targetIndex: Int) {
        model.moveGroup(from: index, before: targetIndex)
        draggedGroupIndex = nil
        groupDropLocation = nil
    }

    private var insertionLine: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 4)
            .shadow(color: Color.accentColor.opacity(0.25), radius: 1)
    }
}

private enum IconLayerDropEdge: Equatable {
    case above
    case below
}

private enum IconGroupDropAnchor: Equatable {
    case document
    case group(index: Int)
}

private struct IconLayerDropLocation {
    let group: Int
    let insertionIndex: Int
    let groupHeader: Int?
    let layerID: UUID?
    let edge: IconLayerDropEdge
}

private struct IconGroupDropLocation: Equatable {
    let insertionIndex: Int
    let anchor: IconGroupDropAnchor
    let edge: IconLayerDropEdge
}

private struct IconLayerDropDelegate: DropDelegate {
    let group: Int
    let insertionIndex: Int
    let groupHeader: Int?
    let layerID: UUID?
    let rowHeight: CGFloat
    @Binding var draggedLayerID: UUID?
    @Binding var dropLocation: IconLayerDropLocation?
    var onMove: (UUID, Int, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedLayerID != nil
    }

    func dropEntered(info: DropInfo) {
        dropLocation = location(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropLocation = location(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedLayerID else { return false }
        let destination = location(for: info)
        onMove(draggedLayerID, destination.group, destination.insertionIndex)
        dropLocation = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if dropLocation?.groupHeader == groupHeader,
           dropLocation?.layerID == layerID {
            dropLocation = nil
        }
    }

    private func location(for info: DropInfo) -> IconLayerDropLocation {
        if let groupHeader {
            return IconLayerDropLocation(
                group: group,
                insertionIndex: insertionIndex,
                groupHeader: groupHeader,
                layerID: nil,
                edge: .below)
        }
        let isLowerHalf = info.location.y > rowHeight / 2
        return IconLayerDropLocation(
            group: group,
            insertionIndex: insertionIndex + (isLowerHalf ? 1 : 0),
            groupHeader: nil,
            layerID: layerID,
            edge: isLowerHalf ? .below : .above)
    }
}

private struct IconGroupDropDelegate: DropDelegate {
    let insertionIndex: Int
    let anchor: IconGroupDropAnchor
    let rowHeight: CGFloat
    @Binding var draggedGroupIndex: Int?
    @Binding var dropLocation: IconGroupDropLocation?
    var onMove: (Int, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedGroupIndex != nil
    }

    func dropEntered(info: DropInfo) {
        dropLocation = location(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropLocation = location(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedGroupIndex else { return false }
        let destination = location(for: info)
        onMove(draggedGroupIndex, destination.insertionIndex)
        dropLocation = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if dropLocation?.anchor == anchor {
            dropLocation = nil
        }
    }

    private func location(for info: DropInfo) -> IconGroupDropLocation {
        if case .document = anchor {
            return IconGroupDropLocation(insertionIndex: insertionIndex,
                                         anchor: anchor,
                                         edge: .above)
        }
        let isLowerHalf = info.location.y > rowHeight / 2
        return IconGroupDropLocation(insertionIndex: insertionIndex + (isLowerHalf ? 1 : 0),
                                     anchor: anchor,
                                     edge: isLowerHalf ? .below : .above)
    }
}

private struct VisibilityButton: View {
    let itemName: String
    let isVisible: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isVisible ? "eye" : "eye.slash")
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isVisible ? .secondary : .tertiary)
        .accessibilityLabel(isVisible ? "Hide \(itemName)" : "Show \(itemName)")
        .help(isVisible ? "Hide \(itemName) in the icon." : "Show \(itemName) in the icon.")
    }
}

private extension UTType {
    static let iconBuilderLayer = UTType(exportedAs: "com.holgerkrupp.iconbuilder.layer-reference")
    static let iconBuilderGroup = UTType(exportedAs: "com.holgerkrupp.iconbuilder.group-reference")
}

/// Small vector thumbnail of a layer's shape.
struct LayerThumb: View {
    let model: AppModel
    let g: Int
    let l: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            if let doc = model.document, let layer = model.layer(g, l) {
                if let shape = doc.shapes[layer.imageName] {
                    GeometryReader { geo in
                        let s = geo.size.width / 1024
                        Path(shape.path)
                            .applying(CGAffineTransform(scaleX: s, y: s))
                            .fill(.secondary)
                    }
                } else if let image = doc.images[layer.imageName] {
                    Image(nsImage: NSImage(cgImage: image, size: NSSize(width: 22, height: 22)))
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
