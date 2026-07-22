import SwiftUI
import AppKit
import ShapeEditingUI

/// SVG editing surface adapted from SymbolBuilder's edit row and snapping
/// canvas, while retaining IconBuilder's final rendered preview underneath.
struct ShapeEditorView: View {
    @Bindable var model: AppModel
    @State private var dragStart: EditableShape?
    @State private var dragTarget: DragTarget?
    @State private var snapLines: [SnapLine] = []
    @State private var measurements: [ShapeMeasurement] = []
    @State private var transformPivot: CGPoint?
    @FocusState private var canvasFocused: Bool

    private enum DragTarget {
        case body(start: CGPoint)
        case selectionBody(last: CGPoint)
        case selectionResize(ShapeResizeHandle, AppModel.SelectionBoundsSnapshot)
        case handle(Int)
        case pathHandle(VectorPathHandle)
        case resize(ShapeResizeHandle, CGRect)
        case rotation(start: CGPoint, pivot: CGPoint)
        case pivot
        case pen
    }

    private struct SnapLine: Equatable {
        var isVertical: Bool
        var value: CGFloat       // final 1024-point icon coordinates
    }

    private static let snapTolerance: CGFloat = 7

    var body: some View {
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
                    drawCanvasAids(context: context, display: display)
                    drawAdditionalSelections(context: context, display: display)
                    drawSelectionBounds(context: context, display: display)
                    if let shape = model.selectedShape {
                        drawPrimary(shape: shape, context: context, transform: shapeToView,
                                    tool: model.canvasTool)
                    }
                    drawSnapLines(context: context, display: display)
                    drawMeasurements(context: context, display: display)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(shapeToView: shapeToView,
                                     node: node, display: display))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onDeleteCommand { model.deleteSelection() }
        .onChange(of: model.selectedLayerIDs) { _, ids in
            if !ids.isEmpty { canvasFocused = true }
        }
        .overlay(alignment: .bottom) { AppearanceSwitcherBar(model: model) }
    }

    private func canvasTransform(for size: CGSize) -> CGAffineTransform {
        let scale = max(0.01, (min(size.width, size.height) - 60) / 1024)
        return CGAffineTransform.identity
            .translatedBy(x: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -512, y: -512)
    }

    private func selectedLayerTransform() -> CGAffineTransform {
        guard let location = model.primarySelectedLayerLocation,
              let group = model.group(location.group),
              group.layers.indices.contains(location.layer) else { return .identity }
        return IconRenderer.layerCanvasTransform(layer: group.layers[location.layer], group: group)
    }

    // MARK: Drawing

    private func drawCanvasAids(context: GraphicsContext, display: CGAffineTransform) {
        if model.canvasSettings.showsGrid {
            let spacing = max(1, model.canvasSettings.gridSpacing)
            var grid = Path()
            var value: CGFloat = 0
            while value <= 1024 {
                grid.move(to: CGPoint(x: value, y: 0).applying(display))
                grid.addLine(to: CGPoint(x: value, y: 1024).applying(display))
                grid.move(to: CGPoint(x: 0, y: value).applying(display))
                grid.addLine(to: CGPoint(x: 1024, y: value).applying(display))
                value += spacing
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }
        var guides = Path()
        for guide in model.canvasSettings.guides {
            if guide.orientation == .vertical {
                guides.move(to: CGPoint(x: guide.position, y: 0).applying(display))
                guides.addLine(to: CGPoint(x: guide.position, y: 1024).applying(display))
            } else {
                guides.move(to: CGPoint(x: 0, y: guide.position).applying(display))
                guides.addLine(to: CGPoint(x: 1024, y: guide.position).applying(display))
            }
        }
        context.stroke(guides, with: .color(.cyan.opacity(0.8)), lineWidth: 1)
    }

    private func drawPrimary(shape: EditableShape, context: GraphicsContext,
                             transform: CGAffineTransform, tool: ShapeCanvasTool) {
        var t = transform
        guard let transformed = shape.path.copy(using: &t) else { return }
        context.stroke(Path(transformed), with: .color(.accentColor), lineWidth: 2.5)

        if tool == .node, shape.kind == .path {
            drawPathNodes(shape: shape, context: context, transform: transform)
            return
        }
        if tool == .select, model.selectedLayerIDs.count > 1 {
            return
        }
        let box = shape.bounds.applying(transform)
        context.stroke(Path(box), with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        for handle in ShapeTransformGeometry.handles(for: box) {
            let rect = CGRect(x: handle.point.x - 5, y: handle.point.y - 5,
                              width: 10, height: 10)
            if handle.kind == .pivot {
                context.stroke(Path(ellipseIn: rect), with: .color(.orange), lineWidth: 1.5)
            } else {
                context.fill(Path(rect), with: .color(.white))
                context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
    }

    private func drawPathNodes(shape: EditableShape, context: GraphicsContext,
                               transform: CGAffineTransform) {
        var stems = Path()
        for (handle, point) in shape.pathHandles where handle.component != .anchor {
            let anchorHandle = VectorPathHandle(subpathIndex: handle.subpathIndex,
                                                nodeIndex: handle.nodeIndex)
            guard let anchor = shape.pathHandles.first(where: { $0.0 == anchorHandle })?.1 else { continue }
            stems.move(to: anchor.applying(transform)); stems.addLine(to: point.applying(transform))
        }
        context.stroke(stems, with: .color(.accentColor.opacity(0.55)), lineWidth: 1)
        for (handle, point) in shape.pathHandles {
            let view = point.applying(transform)
            let size: CGFloat = handle.component == .anchor ? 10 : 8
            let rect = CGRect(x: view.x - size / 2, y: view.y - size / 2,
                              width: size, height: size)
            if handle.component == .anchor {
                context.fill(Path(rect), with: .color(.white))
                context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(.white))
                context.stroke(Path(ellipseIn: rect), with: .color(.accentColor), lineWidth: 1.25)
            }
        }
    }

    private func drawAdditionalSelections(context: GraphicsContext, display: CGAffineTransform) {
        guard let document = model.document else { return }
        let primaryID = model.primarySelectedLayerLocation.flatMap {
            model.layer($0.group, $0.layer)?.id
        }
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

    private func drawSelectionBounds(context: GraphicsContext, display: CGAffineTransform) {
        guard model.canvasTool == .select,
              model.selectedLayerIDs.count > 1,
              let bounds = model.selectedCanvasBounds else { return }
        let box = bounds.applying(display)
        context.stroke(Path(box), with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        for handle in ShapeTransformGeometry.handles(for: box) {
            guard case .resize = handle.kind else { continue }
            let rect = CGRect(x: handle.point.x - 5, y: handle.point.y - 5,
                              width: 10, height: 10)
            context.fill(Path(rect), with: .color(.white))
            context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5)
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

    private func drawMeasurements(context: GraphicsContext, display: CGAffineTransform) {
        guard model.canvasSettings.showsMeasurements else { return }
        for measurement in measurements {
            let start = measurement.start.applying(display)
            let end = measurement.end.applying(display)
            var path = Path(); path.move(to: start); path.addLine(to: end)
            context.stroke(path, with: .color(.orange.opacity(0.85)), lineWidth: 1)
            context.draw(Text(measurement.label).font(.caption2).foregroundStyle(.orange),
                         at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        }
    }

    // MARK: Interaction

    private func dragGesture(shapeToView: CGAffineTransform, node: CGAffineTransform,
                             display: CGAffineTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.canvasTool == .pen, dragTarget == nil {
                    if var current = model.selectedShape, current.kind == .path {
                        let point = value.location.applying(shapeToView.inverted())
                        model.beginUndoTransaction()
                        current.appendPathPoint(point,
                                                subpathIndex: current.pathHandles.map { $0.0.subpathIndex }.max())
                        model.updateSelectedShape(current)
                    } else {
                        model.addPenPath(at: value.location.applying(display.inverted()))
                    }
                    dragTarget = .pen
                    return
                }
                guard let current = model.selectedShape else { return }
                let rawPoint = value.location.applying(shapeToView.inverted())
                let canvasPoint = value.location.applying(display.inverted())
                if dragTarget == nil {
                    dragStart = current
                    if model.canvasTool == .select,
                       let selection = model.selectionBoundsSnapshot(),
                       selection.items.count > 1 {
                        let viewBounds = selection.bounds.applying(display)
                        if let match = ShapeTransformGeometry.handles(for: viewBounds).first(where: {
                            if case .resize = $0.kind {
                                return distance($0.point, value.startLocation) <= 14
                            }
                            return false
                        }) {
                            if case .resize(let handle) = match.kind {
                                dragTarget = .selectionResize(handle, selection)
                                model.beginUndoTransaction()
                                return
                            }
                        }
                        if viewBounds.insetBy(dx: -12, dy: -12).contains(value.startLocation) {
                            dragTarget = .selectionBody(last: canvasPoint)
                            model.beginUndoTransaction()
                            return
                        }
                    }
                    if model.canvasTool == .node, current.kind == .path,
                       let match = current.pathHandles.min(by: {
                           distance($0.1.applying(shapeToView), value.startLocation)
                               < distance($1.1.applying(shapeToView), value.startLocation)
                       }), distance(match.1.applying(shapeToView), value.startLocation) <= 14 {
                        dragTarget = .pathHandle(match.0)
                        model.selectedPathHandle = match.0
                        model.beginUndoTransaction()
                    }
                    if dragTarget == nil, model.canvasTool == .select {
                        let viewBounds = current.bounds.applying(shapeToView)
                        if let match = ShapeTransformGeometry.handles(for: viewBounds).min(by: {
                            distance($0.point, value.startLocation) < distance($1.point, value.startLocation)
                        }), distance(match.point, value.startLocation) <= 14 {
                            switch match.kind {
                            case .resize(let handle): dragTarget = .resize(handle, current.bounds)
                            case .rotation:
                                dragTarget = .rotation(
                                    start: rawPoint,
                                    pivot: transformPivot ?? CGPoint(x: current.bounds.midX,
                                                                     y: current.bounds.midY))
                            case .pivot: dragTarget = .pivot
                            }
                            model.beginUndoTransaction()
                        }
                    }
                    if dragTarget != nil { return }
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
                    } else {
                        // Nothing on the current shape: retarget the selection
                        // to whatever else sits under the click, and let the
                        // next drag update move it.
                        let modifiers = NSEvent.modifierFlags
                        let displayScale = sqrt(abs(display.a * display.d - display.b * display.c))
                        model.selectLayer(at: value.startLocation.applying(display.inverted()),
                                          tolerance: Self.snapTolerance / max(displayScale, 0.01),
                                          extend: modifiers.contains(.shift),
                                          toggle: modifiers.contains(.command))
                        dragStart = nil
                        return
                    }
                }

                guard let dragTarget else { return }
                let modifiers = NSEvent.modifierFlags
                let shouldSnap = model.snapEnabled && !modifiers.contains(.command)
                let displayScale = sqrt(abs(display.a * display.d - display.b * display.c))
                let tolerance = Self.snapTolerance / max(displayScale, 0.01)
                var lines: [SnapLine] = []

                switch dragTarget {
                case .body(let start):
                    guard var shape = dragStart else { return }
                    var delta = CGPoint(x: rawPoint.x - start.x, y: rawPoint.y - start.y)
                    if modifiers.contains(.shift) {
                        if abs(delta.x) >= abs(delta.y) { delta.y = 0 } else { delta.x = 0 }
                    }
                    shape.move(by: delta)
                    if shouldSnap {
                        applyMoveSnap(to: &shape, node: node,
                                      tolerance: tolerance, lines: &lines)
                    }
                    snapLines = lines
                    model.updateSelectedShape(shape)
                case .selectionBody(let last):
                    var delta = CGPoint(x: canvasPoint.x - last.x, y: canvasPoint.y - last.y)
                    if modifiers.contains(.shift) {
                        if abs(delta.x) >= abs(delta.y) { delta.y = 0 } else { delta.x = 0 }
                    }
                    self.dragTarget = .selectionBody(
                        last: CGPoint(x: last.x + delta.x, y: last.y + delta.y))
                    if let snapshot = model.selectionBoundsSnapshot() {
                        model.translateSelection(snapshot, by: delta)
                    }
                    snapLines = []
                    return
                case .selectionResize(let handle, let snapshot):
                    let target = ShapeTransformGeometry.resizedBounds(
                        from: snapshot.bounds, handle: handle, to: canvasPoint,
                        lockAspectRatio: modifiers.contains(.shift),
                        fromCenter: modifiers.contains(.option))
                    snapLines = []
                    model.resizeSelectionBounds(snapshot, to: target)
                    return
                case .handle(let index):
                    guard var shape = dragStart else { return }
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
                    snapLines = lines
                    model.updateSelectedShape(shape)
                case .pathHandle(let handle):
                    guard var shape = dragStart else { return }
                    var target = rawPoint
                    if shouldSnap {
                        var finalTarget = target.applying(node)
                        finalTarget = snapPoint(finalTarget, tolerance: tolerance, lines: &lines)
                        target = finalTarget.applying(node.inverted())
                    }
                    shape.movePathHandle(handle, to: target)
                    snapLines = lines
                    model.updateSelectedShape(shape)
                case .resize(let handle, let original):
                    guard var shape = dragStart else { return }
                    let target = ShapeTransformGeometry.resizedBounds(
                        from: original, handle: handle, to: rawPoint,
                        lockAspectRatio: modifiers.contains(.shift),
                        fromCenter: modifiers.contains(.option))
                    shape.setBounds(target)
                    snapLines = lines
                    model.updateSelectedShape(shape)
                case .rotation(let start, let pivot):
                    guard var shape = dragStart else { return }
                    let degrees = ShapeTransformGeometry.rotation(
                        from: start, to: rawPoint, around: pivot,
                        snapping: modifiers.contains(.shift) ? 15 : nil)
                    var transformation = shape.transformation
                    transformation.rotationDegrees += Double(degrees)
                    shape.transformation = transformation
                    snapLines = lines
                    model.updateSelectedShape(shape)
                case .pivot:
                    transformPivot = rawPoint
                    return
                case .pen:
                    return
                }
            }
            .onEnded { _ in
                if dragTarget != nil { model.endUndoTransaction() }
                dragStart = nil
                dragTarget = nil
                snapLines = []
                measurements = []
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
        if model.canvasSettings.snapToGuides {
            xs += model.canvasSettings.guides.filter { $0.orientation == .vertical }.map(\.position)
            ys += model.canvasSettings.guides.filter { $0.orientation == .horizontal }.map(\.position)
        }
        guard let document = model.document else { return (xs, ys) }
        var union = CGRect.null
        for group in document.manifest.groups where !group.hidden && model.canvasSettings.snapToObjects {
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

    private func snapPoint(_ point: CGPoint, tolerance: CGFloat,
                           lines: inout [SnapLine]) -> CGPoint {
        var candidates = snapCandidates()
        if model.canvasSettings.snapToGrid {
            let spacing = max(1, model.canvasSettings.gridSpacing)
            candidates.xs.append((point.x / spacing).rounded() * spacing)
            candidates.ys.append((point.y / spacing).rounded() * spacing)
        }
        let result = ShapeSnapping.snap(point: point,
                                        verticalCandidates: candidates.xs,
                                        horizontalCandidates: candidates.ys,
                                        tolerance: tolerance)
        if let x = result.verticalGuide { lines.append(SnapLine(isVertical: true, value: x)) }
        if let y = result.horizontalGuide { lines.append(SnapLine(isVertical: false, value: y)) }
        return CGPoint(x: point.x + result.translation.x, y: point.y + result.translation.y)
    }

    private func applyMoveSnap(to shape: inout EditableShape, node: CGAffineTransform,
                               tolerance: CGFloat, lines: inout [SnapLine]) {
        var transform = node
        guard let finalPath = shape.path.copy(using: &transform) else { return }
        let bounds = finalPath.boundingBoxOfPath
        let others = otherVisibleBounds()
        let smart = ShapeSmartGuides.evaluate(
            moving: bounds, others: model.canvasSettings.snapToObjects ? others : [],
            guides: model.canvasSettings.snapToGuides ? model.canvasSettings.guides : [],
            canvas: CGRect(x: 0, y: 0, width: 1024, height: 1024),
            tolerance: tolerance)
        measurements = model.canvasSettings.showsMeasurements ? smart.measurements : []
        if smart.snap.translation != .zero {
            let inverse = node.inverted()
            let vectorTransform = CGAffineTransform(a: inverse.a, b: inverse.b,
                                                    c: inverse.c, d: inverse.d, tx: 0, ty: 0)
            let rawDelta = smart.snap.translation.applying(vectorTransform)
            shape.move(by: rawDelta)
        }
        if let x = smart.snap.verticalGuide { lines.append(SnapLine(isVertical: true, value: x)) }
        if let y = smart.snap.horizontalGuide { lines.append(SnapLine(isVertical: false, value: y)) }
    }

    private func otherVisibleBounds() -> [CGRect] {
        guard let document = model.document else { return [] }
        var result: [CGRect] = []
        for group in document.manifest.groups where !group.hidden {
            for layer in group.layers where !layer.hidden && !model.selectedLayerIDs.contains(layer.id) {
                let transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)
                if let shape = document.shapes[layer.imageName] {
                    var applied = transform
                    if let bounds = shape.path.copy(using: &applied)?.boundingBoxOfPath {
                        result.append(bounds)
                    }
                } else if document.images[layer.imageName] != nil {
                    result.append(CGRect(x: 0, y: 0, width: 1024, height: 1024)
                        .applying(transform))
                }
            }
        }
        return result
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

/// Compact edit row matching SymbolBuilder: quick shapes, library, import,
/// Boolean combine, undo/redo, snapping, and deletion.
struct IconShapeEditRow: View {
    @Bindable var model: AppModel

    private static let quickKinds: [IconShapeKind] = [.line, .curve, .rectangle, .ellipse, .star]
    private static let sections: [(String, [IconShapeKind])] = [
        ("Text", [.text]),
        ("Lines", [.line, .curve]),
        ("Basic", [.circle, .ellipse, .rectangle, .roundedRectangle]),
        ("Polygons", [.triangle, .diamond, .star]),
        ("Symbols", [.arrow])
    ]

    var body: some View {
        ShapeEditorToolbar(
            quickTools: Self.quickKinds.map(\.toolbarTool),
            sections: Self.sections.map { section in
                ShapeEditorToolSection(section.0, tools: section.1.map(\.toolbarTool))
            },
            snappingEnabled: $model.snapEnabled,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            hasSelection: !model.selectedLayerIDs.isEmpty,
            canCombineShapes: model.canCombineSelectedShapes,
            canSplitShapes: model.canSplitSelectedShapes,
            canCreateShapesFromHoles: model.canCreateShapesFromHoles,
            canDistributeShapes: model.canDistributeSelectedObjects,
            addShape: { id in
                if let kind = IconShapeKind(rawValue: id) { model.addShape(kind) }
            },
            importSVG: { model.importSVG() },
            booleanOperation: { model.combineSelectedShapes($0) },
            distributeShapes: { model.distributeSelectedObjects($0) },
            canvasTool: model.canvasTool,
            setCanvasTool: { model.canvasTool = $0 },
            canEditNodes: model.selectedShape?.kind == .path,
            canArrangeShapes: !model.selectedLayerIDs.isEmpty,
            selectionOperation: { model.performSelectionOperation($0) },
            deleteSelection: { model.deleteSelection() },
            undo: { model.undo() },
            redo: { model.redo() }
        )
    }
}

private extension IconShapeKind {
    var toolbarTool: ShapeEditorTool {
        ShapeEditorTool(id: rawValue, title: displayName, systemImage: systemImage)
    }
}
