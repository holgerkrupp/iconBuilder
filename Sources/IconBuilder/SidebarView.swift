import SwiftUI
import IconBuilderCore

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
                    rowView(row).tag(row.selection)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selectionBinding: Binding<NodeSelection?> {
        Binding(get: { model.selection },
                set: { model.selection = $0 ?? .document })
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
        }
    }
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
