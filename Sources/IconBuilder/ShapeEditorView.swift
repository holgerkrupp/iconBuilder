import SwiftUI
import AppKit
import IconBuilderCore

/// SVG editing surface adapted from SymbolBuilder's edit row and snapping
/// canvas, while retaining IconBuilder's final rendered preview underneath.
struct ShapeEditorView: View {
    @Bindable var model: AppModel
    @State private var dragStart: EditableShape?
    @State private var dragTarget: DragTarget?
    @State private var snapLines: [SnapLine] = []

    private enum DragTarget {
        case body(start: CGPoint)
        case handle(Int)
    }

    private struct SnapLine: Equatable {
        var isVertical: Bool
        var value: CGFloat       // final 1024-point icon coordinates
    }

    private static let snapTolerance: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            IconShapeEditRow(model: model)
            Divider()
            GeometryReader { geometry in
                let display = canvasTransform(for: geometry.size)
                let node = selectedLayerTransform()
                let shapeToView = node.concatenating(display)
                ZStack {
                    CheckerboardBackground()
                    if let image = model.previewImage {
                        Image(nsImage: NSImage(cgImage: image,
                                               size: NSSize(width: 1024, height: 1024)))
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(30)
                            .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    }
                    Canvas { context, _ in
                        drawAdditionalSelections(context: context, display: display)
                        if let shape = model.selectedShape {
                            drawPrimary(shape: shape, context: context, transform: shapeToView)
                        }
                        drawSnapLines(context: context, display: display)
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(shapeToView: shapeToView,
                                         node: node, display: display))
                }
            }
        }
        .onDeleteCommand { model.deleteSelection() }
    }

    private func canvasTransform(for size: CGSize) -> CGAffineTransform {
        let scale = max(0.01, (min(size.width, size.height) - 60) / 1024)
        return CGAffineTransform.identity
            .translatedBy(x: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -512, y: -512)
    }

    private func selectedLayerTransform() -> CGAffineTransform {
        guard case .layer(let groupIndex, let layerIndex) = model.selection,
              let group = model.group(groupIndex),
              group.layers.indices.contains(layerIndex) else { return .identity }
        return IconRenderer.layerCanvasTransform(layer: group.layers[layerIndex], group: group)
    }

    // MARK: Drawing

    private func drawPrimary(shape: EditableShape, context: GraphicsContext,
                             transform: CGAffineTransform) {
        var t = transform
        guard let transformed = shape.path.copy(using: &t) else { return }
        context.stroke(Path(transformed), with: .color(.accentColor), lineWidth: 2.5)

        let box = shape.bounds.applying(transform)
        context.stroke(Path(box), with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        for handle in shape.handles.map({ $0.applying(transform) }) {
            let rect = CGRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rect), with: .color(.white))
            context.stroke(Path(ellipseIn: rect), with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    private func drawAdditionalSelections(context: GraphicsContext, display: CGAffineTransform) {
        guard let document = model.document else { return }
        let primaryID: UUID? = {
            guard case .layer(let g, let l) = model.selection else { return nil }
            return model.layer(g, l)?.id
        }()
        for group in document.manifest.groups where !group.hidden {
            for layer in group.layers where !layer.hidden
                && model.selectedLayerIDs.contains(layer.id) && layer.id != primaryID {
                guard let shape = document.shapes[layer.imageName] else { continue }
                var transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                    .concatenating(display)
                if let path = shape.path.copy(using: &transform) {
                    context.stroke(Path(path), with: .color(.accentColor.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
        }
    }

    private func drawSnapLines(context: GraphicsContext, display: CGAffineTransform) {
        guard !snapLines.isEmpty else { return }
        var path = Path()
        for line in snapLines {
            if line.isVertical {
                path.move(to: CGPoint(x: line.value, y: 0).applying(display))
                path.addLine(to: CGPoint(x: line.value, y: 1024).applying(display))
            } else {
                path.move(to: CGPoint(x: 0, y: line.value).applying(display))
                path.addLine(to: CGPoint(x: 1024, y: line.value).applying(display))
            }
        }
        context.stroke(path, with: .color(.red.opacity(0.7)), lineWidth: 1)
    }

    // MARK: Interaction

    private func dragGesture(shapeToView: CGAffineTransform, node: CGAffineTransform,
                             display: CGAffineTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let current = model.selectedShape else { return }
                let rawPoint = value.location.applying(shapeToView.inverted())
                if dragTarget == nil {
                    dragStart = current
                    let handles = current.handles.map { $0.applying(shapeToView) }
                    if let index = handles.indices.min(by: {
                        distance(handles[$0], value.startLocation) < distance(handles[$1], value.startLocation)
                    }), distance(handles[index], value.startLocation) <= 14 {
                        dragTarget = .handle(index)
                        model.beginUndoTransaction()
                    } else if current.path.contains(rawPoint, using: .evenOdd)
                                || current.bounds.insetBy(dx: -12, dy: -12).contains(rawPoint) {
                        dragTarget = .body(start: value.startLocation.applying(shapeToView.inverted()))
                        model.beginUndoTransaction()
                    }
                }

                guard var shape = dragStart, let dragTarget else { return }
                let modifiers = NSEvent.modifierFlags
                let shouldSnap = model.snapEnabled && !modifiers.contains(.command)
                let displayScale = sqrt(abs(display.a * display.d - display.b * display.c))
                let tolerance = Self.snapTolerance / max(displayScale, 0.01)
                var lines: [SnapLine] = []

                switch dragTarget {
                case .body(let start):
                    var delta = CGPoint(x: rawPoint.x - start.x, y: rawPoint.y - start.y)
                    if modifiers.contains(.shift) {
                        if abs(delta.x) >= abs(delta.y) { delta.y = 0 } else { delta.x = 0 }
                    }
                    shape.move(by: delta)
                    if shouldSnap {
                        applyMoveSnap(to: &shape, node: node,
                                      tolerance: tolerance, lines: &lines)
                    }
                case .handle(let index):
                    var target = rawPoint
                    if modifiers.contains(.shift) {
                        target = aspectConstrainedTarget(target, shape: shape, handleIndex: index)
                    }
                    if shouldSnap {
                        var finalTarget = target.applying(node)
                        finalTarget = snapPoint(finalTarget, tolerance: tolerance, lines: &lines)
                        target = finalTarget.applying(node.inverted())
                    }
                    shape.setHandle(index, to: target)
                }
                snapLines = lines
                model.updateSelectedShape(shape)
            }
            .onEnded { _ in
                if dragTarget != nil { model.endUndoTransaction() }
                dragStart = nil
                dragTarget = nil
                snapLines = []
            }
    }

    private func aspectConstrainedTarget(_ target: CGPoint, shape: EditableShape,
                                         handleIndex: Int) -> CGPoint {
        let bounds = shape.bounds
        guard bounds.width > 0, bounds.height > 0 else { return target }
        let index = handleIndex % 4
        let opposite = [CGPoint(x: bounds.maxX, y: bounds.maxY),
                        CGPoint(x: bounds.minX, y: bounds.maxY),
                        CGPoint(x: bounds.minX, y: bounds.minY),
                        CGPoint(x: bounds.maxX, y: bounds.minY)][index]
        let xSigns: [CGFloat] = [-1, 1, 1, -1]
        let ySigns: [CGFloat] = [-1, -1, 1, 1]
        let ratio = bounds.width / bounds.height
        var width = abs(target.x - opposite.x)
        var height = abs(target.y - opposite.y)
        if width / bounds.width >= height / bounds.height { height = width / ratio }
        else { width = height * ratio }
        return CGPoint(x: opposite.x + xSigns[index] * width,
                       y: opposite.y + ySigns[index] * height)
    }

    // MARK: Snapping

    /// Canvas edges/center plus every other visible layer's edges and centers,
    /// all measured in final icon coordinates after group and layer transforms.
    private func snapCandidates() -> (xs: [CGFloat], ys: [CGFloat]) {
        var xs: [CGFloat] = [0, 512, 1024]
        var ys: [CGFloat] = [0, 512, 1024]
        guard let document = model.document else { return (xs, ys) }
        var union = CGRect.null
        for group in document.manifest.groups where !group.hidden {
            for layer in group.layers where !layer.hidden && !model.selectedLayerIDs.contains(layer.id) {
                let bounds: CGRect?
                let transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                if let shape = document.shapes[layer.imageName] {
                    var t = transform
                    bounds = shape.path.copy(using: &t)?.boundingBoxOfPath
                } else if document.images[layer.imageName] != nil {
                    bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024).applying(transform)
                } else {
                    bounds = nil
                }
                guard let bounds, !bounds.isNull, !bounds.isEmpty else { continue }
                union = union.union(bounds)
                xs += [bounds.minX, bounds.midX, bounds.maxX]
                ys += [bounds.minY, bounds.midY, bounds.maxY]
            }
        }
        if !union.isNull {
            xs += [union.minX, union.midX, union.maxX]
            ys += [union.minY, union.midY, union.maxY]
        }
        return (xs, ys)
    }

    private func nearest(_ value: CGFloat, in candidates: [CGFloat],
                         tolerance: CGFloat) -> CGFloat? {
        candidates.map { ($0, abs($0 - value)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    private func snapPoint(_ point: CGPoint, tolerance: CGFloat,
                           lines: inout [SnapLine]) -> CGPoint {
        let candidates = snapCandidates()
        var result = point
        if let x = nearest(point.x, in: candidates.xs, tolerance: tolerance) {
            result.x = x; lines.append(SnapLine(isVertical: true, value: x))
        }
        if let y = nearest(point.y, in: candidates.ys, tolerance: tolerance) {
            result.y = y; lines.append(SnapLine(isVertical: false, value: y))
        }
        return result
    }

    private func applyMoveSnap(to shape: inout EditableShape, node: CGAffineTransform,
                               tolerance: CGFloat, lines: inout [SnapLine]) {
        var transform = node
        guard let finalPath = shape.path.copy(using: &transform) else { return }
        let bounds = finalPath.boundingBoxOfPath
        let candidates = snapCandidates()
        var bestDX: CGFloat?
        var bestDY: CGFloat?
        var snapX: CGFloat = 0
        var snapY: CGFloat = 0
        for edge in [bounds.minX, bounds.midX, bounds.maxX] {
            if let candidate = nearest(edge, in: candidates.xs, tolerance: tolerance) {
                let delta = candidate - edge
                if bestDX == nil || abs(delta) < abs(bestDX!) { bestDX = delta; snapX = candidate }
            }
        }
        for edge in [bounds.minY, bounds.midY, bounds.maxY] {
            if let candidate = nearest(edge, in: candidates.ys, tolerance: tolerance) {
                let delta = candidate - edge
                if bestDY == nil || abs(delta) < abs(bestDY!) { bestDY = delta; snapY = candidate }
            }
        }
        if bestDX != nil || bestDY != nil {
            let inverse = node.inverted()
            let vectorTransform = CGAffineTransform(a: inverse.a, b: inverse.b,
                                                    c: inverse.c, d: inverse.d, tx: 0, ty: 0)
            let rawDelta = CGPoint(x: bestDX ?? 0, y: bestDY ?? 0).applying(vectorTransform)
            shape.move(by: rawDelta)
        }
        if bestDX != nil { lines.append(SnapLine(isVertical: true, value: snapX)) }
        if bestDY != nil { lines.append(SnapLine(isVertical: false, value: snapY)) }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

/// Compact edit row matching SymbolBuilder: quick shapes, library, import,
/// Boolean combine, undo/redo, snapping, and deletion.
private struct IconShapeEditRow: View {
    @Bindable var model: AppModel

    private static let quickKinds: [IconShapeKind] = [.line, .curve, .rectangle, .ellipse, .star]
    private static let sections: [(String, [IconShapeKind])] = [
        ("Lines", [.line, .curve]),
        ("Basic", [.circle, .ellipse, .rectangle, .roundedRectangle]),
        ("Polygons", [.triangle, .diamond, .star]),
        ("Symbols", [.arrow])
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(Self.quickKinds) { kind in
                Button { model.addShape(kind) } label: {
                    Image(systemName: kind.systemImage).frame(width: 24, height: 20)
                }
                .buttonStyle(.bordered)
                .help("Add \(kind.displayName)")
            }
            Menu {
                ForEach(Array(Self.sections.enumerated()), id: \.offset) { _, section in
                    Section(section.0) {
                        ForEach(section.1) { kind in
                            Button { model.addShape(kind) } label: {
                                Label(kind.displayName, systemImage: kind.systemImage)
                            }
                        }
                    }
                }
            } label: {
                Label("Shape Library", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 18)
            Button { model.importSVG() } label: {
                Label("Import SVG", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 18)
            Menu {
                ForEach(ShapeBooleanOperation.allCases) { operation in
                    Button(operation.displayName) { model.combineSelectedShapes(operation) }
                        .help(operation.helpText)
                }
            } label: {
                Label("Combine", systemImage: "square.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!model.canCombineSelectedShapes)
            .help(model.canCombineSelectedShapes
                  ? "Combine selected vector layers"
                  : "Command-click two or more vector layers in the sidebar")

            Divider().frame(height: 18)
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 20)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canUndo)
            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 24, height: 20)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canRedo)

            Divider().frame(height: 18)
            Toggle(isOn: $model.snapEnabled) {
                Image(systemName: "align.horizontal.center").frame(width: 24, height: 20)
            }
            .toggleStyle(.button)
            .help("Snap to canvas and layer alignment guides. Hold Command to bypass.")

            Spacer(minLength: 4)
            Button(role: .destructive) { model.deleteSelection() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedLayerIDs.isEmpty)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
    }
}
