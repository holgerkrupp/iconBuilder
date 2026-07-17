import Foundation
import CoreGraphics

/// Parametric geometry used by the basic icon shape editor. The approach is
/// adapted from SymbolBuilder's ShapeSpec, but uses Icon Composer's fixed
/// 1024×1024, top-left-origin authoring space.
public enum IconShapeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case path
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

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .path: return "Path"
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

    public var systemImage: String {
        switch self {
        case .path: return "point.topleft.down.to.point.bottomright.curvepath"
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
}

public struct EditableShape: Sendable, Equatable {
    public var kind: IconShapeKind
    public var frame: CGRect
    public var cornerRadius: Double
    public var pathData: String?

    public init(kind: IconShapeKind, frame: CGRect, cornerRadius: Double = 64,
                pathData: String? = nil) {
        self.kind = kind
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.pathData = pathData
    }

    public init(shape: SVGShape) {
        self.kind = .path
        self.frame = shape.path.boundingBoxOfPath
        self.cornerRadius = 0
        self.pathData = shape.path.svgPathData
    }

    public static func starter(_ kind: IconShapeKind) -> EditableShape {
        let square = CGRect(x: 312, y: 312, width: 400, height: 400)
        let frame: CGRect
        switch kind {
        case .line, .curve: frame = CGRect(x: 262, y: 362, width: 500, height: 300)
        case .ellipse: frame = CGRect(x: 252, y: 352, width: 520, height: 320)
        case .arrow: frame = CGRect(x: 232, y: 342, width: 560, height: 340)
        default: frame = square
        }
        return EditableShape(kind: kind == .path ? .rectangle : kind, frame: frame)
    }

    public var bounds: CGRect {
        kind == .path ? path.boundingBoxOfPath : frame.standardized
    }

    public var handles: [CGPoint] {
        let b = bounds
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
    }

    public var path: CGPath {
        let f = frame.standardized
        switch kind {
        case .path:
            return pathData.map(SVGPathParser.path(fromData:)) ?? CGMutablePath()
        case .line:
            let centerline = CGMutablePath()
            centerline.move(to: CGPoint(x: f.minX, y: f.maxY))
            centerline.addLine(to: CGPoint(x: f.maxX, y: f.minY))
            return centerline.copy(strokingWithWidth: 28, lineCap: .round,
                                   lineJoin: .round, miterLimit: 10)
        case .curve:
            let centerline = CGMutablePath()
            centerline.move(to: CGPoint(x: f.minX, y: f.maxY))
            centerline.addCurve(to: CGPoint(x: f.maxX, y: f.minY),
                                control1: CGPoint(x: f.minX + f.width * 0.3, y: f.minY),
                                control2: CGPoint(x: f.minX + f.width * 0.7, y: f.maxY))
            return centerline.copy(strokingWithWidth: 28, lineCap: .round,
                                   lineJoin: .round, miterLimit: 10)
        case .rectangle:
            return CGPath(rect: f, transform: nil)
        case .roundedRectangle:
            let r = min(CGFloat(cornerRadius), min(f.width, f.height) / 2)
            return CGPath(roundedRect: f, cornerWidth: r, cornerHeight: r, transform: nil)
        case .circle:
            let side = min(f.width, f.height)
            return CGPath(ellipseIn: CGRect(x: f.midX - side / 2, y: f.midY - side / 2,
                                            width: side, height: side), transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: f, transform: nil)
        case .triangle:
            return polygon(in: f, points: [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1),
                                           CGPoint(x: 0, y: 1)])
        case .diamond:
            return polygon(in: f, points: [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5),
                                           CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)])
        case .star:
            let points = (0..<10).map { index -> CGPoint in
                let angle = -.pi / 2 + .pi * CGFloat(index) / 5
                let radius: CGFloat = index.isMultiple(of: 2) ? 0.5 : 0.22
                return CGPoint(x: 0.5 + radius * cos(angle), y: 0.5 + radius * sin(angle))
            }
            return polygon(in: f, points: points)
        case .arrow:
            return polygon(in: f, points: [
                CGPoint(x: 0, y: 0.32), CGPoint(x: 0.54, y: 0.32),
                CGPoint(x: 0.54, y: 0.08), CGPoint(x: 1, y: 0.5),
                CGPoint(x: 0.54, y: 0.92), CGPoint(x: 0.54, y: 0.68),
                CGPoint(x: 0, y: 0.68)
            ])
        }
    }

    public mutating func move(by delta: CGPoint) {
        if kind == .path {
            transformPath(CGAffineTransform(translationX: delta.x, y: delta.y))
        } else {
            frame = frame.offsetBy(dx: delta.x, dy: delta.y)
        }
    }

    public mutating func setHandle(_ index: Int, to point: CGPoint) {
        let old = bounds.standardized
        guard !old.isNull, !old.isEmpty else { return }
        let opposite = [CGPoint(x: old.maxX, y: old.maxY), CGPoint(x: old.minX, y: old.maxY),
                        CGPoint(x: old.minX, y: old.minY), CGPoint(x: old.maxX, y: old.minY)][index % 4]
        let target = CGRect(x: min(point.x, opposite.x), y: min(point.y, opposite.y),
                            width: max(2, abs(point.x - opposite.x)),
                            height: max(2, abs(point.y - opposite.y)))
        resize(from: old, to: target)
    }

    public mutating func setBounds(_ target: CGRect) {
        resize(from: bounds.standardized, to: target.standardized)
    }

    private mutating func resize(from old: CGRect, to target: CGRect) {
        guard old.width > 0.0001, old.height > 0.0001 else { return }
        if kind == .path {
            let transform = CGAffineTransform.identity
                .translatedBy(x: target.minX, y: target.minY)
                .scaledBy(x: target.width / old.width, y: target.height / old.height)
                .translatedBy(x: -old.minX, y: -old.minY)
            transformPath(transform)
        } else {
            frame = target
        }
    }

    private mutating func transformPath(_ transform: CGAffineTransform) {
        var t = transform
        if let transformed = path.copy(using: &t) {
            pathData = transformed.svgPathData
            frame = transformed.boundingBoxOfPath
        }
    }

    public var svgData: Data {
        let escaped = path.svgPathData
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
          <path d="\(escaped)" fill="#000000" fill-rule="evenodd"/>
        </svg>
        """
        return Data(text.utf8)
    }

    private func polygon(in rect: CGRect, points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        path.move(to: map(first))
        for point in points.dropFirst() { path.addLine(to: map(point)) }
        path.closeSubpath()
        return path
    }
}

public extension CGPath {
    /// Absolute SVG path commands, shared with SymbolBuilder's exporter.
    var svgPathData: String {
        var result = ""
        func format(_ value: CGFloat) -> String {
            var text = String(format: "%.5f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text.isEmpty || text == "-0" ? "0" : text
        }
        applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                result += "M\(format(e.points[0].x)) \(format(e.points[0].y))"
            case .addLineToPoint:
                result += "L\(format(e.points[0].x)) \(format(e.points[0].y))"
            case .addQuadCurveToPoint:
                result += "Q\(format(e.points[0].x)) \(format(e.points[0].y)) \(format(e.points[1].x)) \(format(e.points[1].y))"
            case .addCurveToPoint:
                result += "C\(format(e.points[0].x)) \(format(e.points[0].y)) \(format(e.points[1].x)) \(format(e.points[1].y)) \(format(e.points[2].x)) \(format(e.points[2].y))"
            case .closeSubpath:
                result += "Z"
            @unknown default:
                break
            }
        }
        return result
    }
}
