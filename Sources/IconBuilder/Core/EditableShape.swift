import Foundation
import CoreGraphics
@_exported import ShapeEditingKit

/// IconBuilder's UI-facing shape names. Geometry and editing behavior are
/// delegated to ShapeEditingKit's app-neutral `ShapeSpec`.
enum IconShapeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case path
    case text
    case line
    case curve
    case rectangle
    case roundedRectangle
    case circle
    case ellipse
    case triangle
    case diamond
    case star
    case arrow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .path: return "Path"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded Rectangle"
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .diamond: return "Diamond"
        case .star: return "Star"
        case .arrow: return "Arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .path: return "point.topleft.down.to.point.bottomright.curvepath"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .curve: return "point.bottomleft.forward.to.point.topright.scurvepath"
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        case .star: return "star"
        case .arrow: return "arrow.right"
        }
    }

    fileprivate var sharedKind: ShapeSpec.Kind {
        switch self {
        case .path: return .path
        case .text: return .text
        case .line: return .line
        case .curve: return .curve
        case .rectangle, .roundedRectangle: return .rect
        case .circle: return .circle
        case .ellipse: return .ellipse
        case .triangle: return .triangle
        case .diamond: return .diamond
        case .star: return .star
        case .arrow: return .arrow
        }
    }
}

struct EditableShape: Sendable, Equatable {
    var kind: IconShapeKind
    private var geometry: ShapeSpec

    var frame: CGRect {
        get { geometry.frame }
        set { geometry.frame = newValue }
    }

    var cornerRadius: Double {
        get { geometry.cornerRadius }
        set { geometry.cornerRadius = newValue }
    }

    var pathData: String? {
        get { geometry.pathData }
        set { geometry.pathData = newValue }
    }

    var text: String {
        get { geometry.text ?? "Text" }
        set { geometry.text = newValue }
    }

    var fontName: String {
        get { geometry.fontName ?? "Helvetica" }
        set { geometry.fontName = newValue }
    }

    var transformation: ShapeTransformation {
        get { geometry.effectiveTransformation }
        set { geometry.transformation = newValue.isIdentity ? nil : newValue }
    }

    var strokeStyle: ShapeStrokeStyle {
        get { geometry.effectiveStrokeStyle }
        set { geometry.strokeStyle = newValue }
    }

    var hasExplicitStrokeStyle: Bool { geometry.strokeStyle != nil }
    var usesStrokeRendering: Bool { geometry.usesStrokeRendering }
    var canToggleFilled: Bool {
        kind != .line && kind != .curve && strokeModeUnavailableReason == nil
    }
    var strokeDefaultWidth: Double { geometry.defaultStrokeWidth }

    var textLayout: ShapeTextLayout {
        get { geometry.effectiveTextLayout }
        set { geometry.textLayout = newValue }
    }

    var isFilled: Bool {
        get { geometry.isFilled }
        set { geometry.isFilled = newValue }
    }

    var hasMask: Bool { geometry.mask != nil }
    var mask: ShapeMask? {
        get { geometry.mask }
        set { geometry.mask = newValue }
    }

    var pathHandles: [(VectorPathHandle, CGPoint)] { geometry.pathHandles }

    var supportsStrokeAlignment: Bool {
        guard usesStrokeRendering else { return false }
        switch kind {
        case .line, .curve:
            return false
        case .path:
            let subpaths = geometry.editableVectorPath?.subpaths.filter { !$0.nodes.isEmpty } ?? []
            return !subpaths.isEmpty && subpaths.allSatisfy(\.isClosed)
        default:
            return true
        }
    }

    var supportsStrokeMarkers: Bool {
        guard usesStrokeRendering else { return false }
        switch kind {
        case .line, .curve:
            return true
        case .path:
            guard let subpath = geometry.editableVectorPath?.subpaths
                .filter({ !$0.nodes.isEmpty }).only else { return false }
            return !subpath.isClosed && subpath.nodes.count >= 2
        default:
            return false
        }
    }

    var strokeModeUnavailableReason: String? {
        guard kind == .path, !geometry.canRenderAsStrokeOutline else { return nil }
        return "This path already contains multiple closed contours. Turning off Filled would stroke every contour and create outlines around outlines, so stroke mode is disabled for this shape."
    }

    init(kind: IconShapeKind, frame: CGRect, cornerRadius: Double = 64,
                pathData: String? = nil) {
        self.kind = kind
        self.geometry = ShapeSpec(
            kind: kind.sharedKind,
            points: Self.points(for: kind, in: frame),
            frame: frame,
            cornerRadius: kind == .rectangle ? 0 : cornerRadius,
            pathData: pathData
        )
        if kind == .text {
            self.geometry.text = "Text"
            self.geometry.fontName = "Helvetica-Bold"
        }
    }

    init(shape: SVGShape, splitComponents: [VectorPath]? = nil) {
        if let spec = shape.editableSpec {
            self.geometry = spec
            if let splitComponents { self.geometry.splitComponents = splitComponents }
            self.kind = IconShapeKind(spec: spec)
            return
        }
        self.kind = .path
        self.geometry = ShapeSpec(kind: .path, frame: shape.path.boundingBoxOfPath,
                                  cornerRadius: 0, pathData: shape.path.svgPathData,
                                  splitComponents: splitComponents)
    }

    init(vectorPath: VectorPath, isFilled: Bool = false) {
        self.kind = .path
        self.geometry = ShapeSpec(kind: .path, frame: vectorPath.bounds,
                                  isFilled: isFilled, vectorPath: vectorPath)
    }

    static func starter(_ kind: IconShapeKind) -> EditableShape {
        let square = CGRect(x: 312, y: 312, width: 400, height: 400)
        let frame: CGRect
        switch kind {
        case .line, .curve: frame = CGRect(x: 262, y: 362, width: 500, height: 300)
        case .text: frame = CGRect(x: 212, y: 392, width: 600, height: 240)
        case .ellipse: frame = CGRect(x: 252, y: 352, width: 520, height: 320)
        case .arrow: frame = CGRect(x: 232, y: 342, width: 560, height: 340)
        default: frame = square
        }
        return EditableShape(kind: kind == .path ? .rectangle : kind, frame: frame)
    }

    var bounds: CGRect {
        path.boundingBoxOfPath
    }

    var handles: [CGPoint] {
        let bounds = bounds
        return [CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.minX, y: bounds.maxY)]
    }

    var path: CGPath {
        if kind == .circle {
            let frame = geometry.frame.standardized
            let side = min(frame.width, frame.height)
            let circle = CGPath(ellipseIn: CGRect(x: frame.midX - side / 2,
                                                  y: frame.midY - side / 2,
                                                  width: side, height: side),
                                transform: nil)
            let transformed = geometry.effectiveTransformation.applying(to: circle)
            if geometry.usesStrokeRendering {
                return transformed.outlined(using: geometry.effectiveStrokeStyle)
            }
            return transformed
        }
        return geometry.renderedPath(defaultStrokeWidth: 28)
    }

    mutating func move(by delta: CGPoint) {
        geometry.move(by: delta)
    }

    mutating func setHandle(_ index: Int, to point: CGPoint) {
        let old = bounds.standardized
        guard !old.isNull, !old.isEmpty else { return }
        let opposite = [CGPoint(x: old.maxX, y: old.maxY), CGPoint(x: old.minX, y: old.maxY),
                        CGPoint(x: old.minX, y: old.minY), CGPoint(x: old.maxX, y: old.minY)][index % 4]
        let target = CGRect(x: min(point.x, opposite.x), y: min(point.y, opposite.y),
                            width: max(2, abs(point.x - opposite.x)),
                            height: max(2, abs(point.y - opposite.y)))
        setBounds(target)
    }

    mutating func setBounds(_ target: CGRect) {
        geometry.setBounds(target)
    }

    mutating func prepareForNodeEditing() { geometry.prepareForNodeEditing() }

    mutating func movePathHandle(_ handle: VectorPathHandle, to point: CGPoint) {
        geometry.movePathHandle(handle, to: point)
    }

    mutating func setPathNodeType(_ type: VectorNodeType, at handle: VectorPathHandle) {
        geometry.setPathNodeType(type, at: handle)
    }

    @discardableResult mutating func removePathNode(at handle: VectorPathHandle) -> Bool {
        geometry.removePathNode(at: handle)
    }

    mutating func splitPath(at handle: VectorPathHandle) { geometry.splitPath(at: handle) }
    mutating func closePath(containing handle: VectorPathHandle) {
        geometry.closePath(containing: handle)
    }
    @discardableResult mutating func joinOpenPaths() -> Bool { geometry.joinOpenPaths() }

    mutating func appendPathPoint(_ point: CGPoint, subpathIndex: Int? = nil) {
        geometry.appendPathPoint(point, subpathIndex: subpathIndex)
    }

    func convertedToOutlines() -> EditableShape {
        EditableShape(spec: geometry.convertedToOutlines(strokeWidth: 28))
    }

    func offset(by distance: CGFloat) -> EditableShape {
        EditableShape(spec: geometry.offset(by: distance))
    }

    func roundingCorners(radius: CGFloat) -> EditableShape {
        EditableShape(spec: geometry.roundingCorners(radius: radius))
    }

    func simplifying(tolerance: CGFloat) -> EditableShape {
        EditableShape(spec: geometry.simplifying(tolerance: tolerance))
    }

    func fillingHoles() -> EditableShape {
        EditableShape(spec: geometry.fillingHoles())
    }

    func applyingMask(_ path: CGPath, inverted: Bool = false) -> EditableShape {
        EditableShape(spec: geometry.applyingMask(path, inverted: inverted))
    }

    func releasingMask() -> EditableShape {
        EditableShape(spec: geometry.releasingMask())
    }

    func repeated(step: Int, transform: ShapeRepeatTransform) -> EditableShape {
        EditableShape(spec: geometry.repeated(step: step, transform: transform))
    }

    func mirrored(across axis: ShapeSymmetryAxis, position: CGFloat) -> EditableShape {
        EditableShape(spec: geometry.mirrored(across: axis, position: position))
    }

    var canSplitIntoSubshapes: Bool { geometry.canSplitIntoSubshapes }
    var canCreateShapesFromHoles: Bool { geometry.canCreateShapesFromHoles }

    func splitIntoSubshapes() -> [EditableShape] {
        geometry.splitIntoSubshapes().map(EditableShape.init(spec:))
    }

    func holeSubshapes() -> [EditableShape] {
        geometry.holeSubshapes().map(EditableShape.init(spec:))
    }

    func attachingText(to path: CGPath) -> EditableShape {
        var spec = geometry
        var layout = spec.effectiveTextLayout
        layout.path = VectorPath(cgPath: path)
        spec.textLayout = layout
        return EditableShape(spec: spec)
    }

    var svgData: Data {
        let data = path.svgPathData
        let metadata = (try? JSONEncoder().encode(geometry))?.base64EncodedString() ?? ""
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
          <metadata id="shape-editing-kit">\(metadata)</metadata>
          <path d="\(data)" fill="#000000" fill-rule="evenodd"/>
        </svg>
        """
        return Data(text.utf8)
    }

    var svgShape: SVGShape {
        SVGShape(path: path, editableSpec: geometry)
    }

    private init(spec: ShapeSpec) {
        geometry = spec
        kind = IconShapeKind(spec: spec)
    }

    private init(kind: IconShapeKind, geometry: ShapeSpec) {
        self.kind = kind
        self.geometry = geometry
    }

    private static func points(for kind: IconShapeKind, in frame: CGRect) -> [CGPoint] {
        switch kind {
        case .line:
            return [CGPoint(x: frame.minX, y: frame.maxY),
                    CGPoint(x: frame.maxX, y: frame.minY)]
        case .curve:
            return [CGPoint(x: frame.minX, y: frame.maxY),
                    CGPoint(x: frame.minX + frame.width * 0.3, y: frame.minY),
                    CGPoint(x: frame.minX + frame.width * 0.7, y: frame.maxY),
                    CGPoint(x: frame.maxX, y: frame.minY)]
        default:
            return []
        }
    }
}

private extension IconShapeKind {
    init(spec: ShapeSpec) {
        switch spec.kind {
        case .path: self = .path
        case .text: self = .text
        case .line: self = .line
        case .curve: self = .curve
        case .circle: self = .circle
        case .ellipse: self = .ellipse
        case .rect: self = spec.cornerRadius > 0 ? .roundedRectangle : .rectangle
        case .triangle: self = .triangle
        case .diamond: self = .diamond
        case .star: self = .star
        case .arrow: self = .arrow
        default: self = .path
        }
    }
}

typealias SVGShape = ShapeEditingKit.SVGShape
typealias SVGPathParser = ShapeEditingKit.SVGPathParser
typealias ShapeBooleanOperation = ShapeEditingKit.ShapeBooleanOperation
typealias ShapeSnapping = ShapeEditingKit.ShapeSnapping
typealias ShapeSnapResult = ShapeEditingKit.ShapeSnapResult

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

enum SVGShapeTestHook {
    static func parseTransform(_ value: String?) -> CGAffineTransform {
        SVGTransformParser.parse(value)
    }
}
