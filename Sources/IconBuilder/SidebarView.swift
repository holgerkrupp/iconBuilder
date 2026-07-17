import SwiftUI
import IconBuilderCore
import UniformTypeIdentifiers

/// Document → groups → layers tree, topmost-first (Icon Composer sidebar order).
/// Rendered as one flat ForEach with globally unique row ids — nested ForEach
/// with per-group integer ids makes the AppKit-backed List recycle rows across
/// groups.
struct SidebarPane: View {
    @Bindable var model: AppModel

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
        List(selection: selectionBinding) {
            if model.document == nil {
                Text("No document").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.selection)
                        .contextMenu {
                            switch row.selection {
                            case .document:
                                Button("Add Group", systemImage: "folder.badge.plus") { model.addGroup() }
                            case .group:
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
                                Button("Edit Shape", systemImage: "pencil.and.outline") {
                                    model.selection = row.selection
                                    model.isShapeEditing = model.selectedShape != nil
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
        .listStyle(.sidebar)
    }

    private var selectionBinding: Binding<Set<NodeSelection>> {
        Binding(get: { model.sidebarSelections },
                set: { model.setSidebarSelections($0) })
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case .document(let name):
            Label(name, systemImage: "app.dashed")
        case .group(let g):
            HStack {
                Label("Group \(g + 1)", systemImage: "folder")
                if model.group(g)?.hidden == true {
                    Spacer()
                    Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8)
            .onDrop(of: [.iconBuilderLayer], isTargeted: nil) { providers in
                acceptLayerDrop(providers, group: g,
                                before: model.group(g)?.layers.count ?? 0)
            }
        case .layer(let g, let l, let layer):
            HStack(spacing: 6) {
                LayerThumb(model: model, g: g, l: l)
                Text(layer.name.isEmpty ? layer.imageName : layer.name)
                    .lineLimit(1)
                if layer.hidden {
                    Spacer()
                    Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 24)
            .onDrag { layerProvider(layer.id) }
            .onDrop(of: [.iconBuilderLayer], isTargeted: nil) { providers in
                acceptLayerDrop(providers, group: g, before: l)
            }
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

    private func acceptLayerDrop(_ providers: [NSItemProvider], group: Int, before index: Int) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.iconBuilderLayer.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.iconBuilderLayer.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: text) else { return }
            Task { @MainActor in model.moveLayer(id: id, toGroup: group, before: index) }
        }
        return true
    }
}

private extension UTType {
    static let iconBuilderLayer = UTType(exportedAs: "com.holgerkrupp.iconbuilder.layer-reference")
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
    }
}
