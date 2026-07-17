import Foundation
import CoreGraphics

/// The vector geometry of a single Icon Composer asset SVG, flattened into one
/// `CGPath` expressed in the SVG viewBox coordinate space (top-left origin, Y-down).
public struct SVGShape: @unchecked Sendable {
    // CGPath is effectively immutable here; safe to treat as Sendable.
    public var path: CGPath
    public var viewBox: CGRect

    public init(path: CGPath, viewBox: CGRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)) {
        self.path = path
        self.viewBox = viewBox
    }

    /// Parse an SVG file. Returns nil if no drawable geometry is found.
    public static func load(url: URL) -> SVGShape? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    public static func parse(data: Data) -> SVGShape? {
        let delegate = SVGParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.combined.isEmpty == false || !delegate.combined.boundingBoxOfPath.isNull else {
            if delegate.combined.isEmpty { return nil }
            return SVGShape(path: delegate.combined, viewBox: delegate.viewBox)
        }
        return SVGShape(path: delegate.combined, viewBox: delegate.viewBox)
    }
}

/// Walks the SVG tree, maintaining a transform stack for `<g>` groups and
/// converting shape elements into `CGPath`s concatenated into one path.
private final class SVGParserDelegate: NSObject, XMLParserDelegate {
    var viewBox = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let combined = CGMutablePath()
    private var transformStack: [CGAffineTransform] = [.identity]

    private var current: CGAffineTransform { transformStack.last ?? .identity }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()

        if name == "svg", let vb = attributeDict["viewBox"] {
            let n = vb.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if n.count == 4 { viewBox = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        }

        // Push any element's own transform; groups keep it for their children.
        let local = SVGParserDelegate.parseTransform(attributeDict["transform"])
        let elementTransform = local.concatenating(current)

        switch name {
        case "g", "svg":
            transformStack.append(elementTransform)
        case "path":
            if let d = attributeDict["d"] {
                append(SVGPathParser.path(fromData: d), transform: elementTransform)
            }
        case "rect":
            append(rectPath(attributeDict), transform: elementTransform)
        case "circle":
            if let cx = dbl(attributeDict["cx"]), let cy = dbl(attributeDict["cy"]),
               let r = dbl(attributeDict["r"]) {
                let p = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
                append(p, transform: elementTransform)
            }
        case "ellipse":
            if let cx = dbl(attributeDict["cx"]), let cy = dbl(attributeDict["cy"]),
               let rx = dbl(attributeDict["rx"]), let ry = dbl(attributeDict["ry"]) {
                let p = CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
                append(p, transform: elementTransform)
            }
        case "polygon", "polyline":
            if let pts = attributeDict["points"] {
                append(polyPath(pts, close: name == "polygon"), transform: elementTransform)
            }
        case "line":
            if let x1 = dbl(attributeDict["x1"]), let y1 = dbl(attributeDict["y1"]),
               let x2 = dbl(attributeDict["x2"]), let y2 = dbl(attributeDict["y2"]) {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2))
                append(p, transform: elementTransform)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "g" || name == "svg" {
            if transformStack.count > 1 { transformStack.removeLast() }
        }
    }

    private func append(_ path: CGPath, transform: CGAffineTransform) {
        var t = transform
        if let transformed = path.copy(using: &t) {
            combined.addPath(transformed)
        }
    }

    private func rectPath(_ a: [String: String]) -> CGPath {
        let x = dbl(a["x"]) ?? 0, y = dbl(a["y"]) ?? 0
        let w = dbl(a["width"]) ?? 0, h = dbl(a["height"]) ?? 0
        let rx = dbl(a["rx"]); let ry = dbl(a["ry"])
        let rect = CGRect(x: x, y: y, width: w, height: h)
        if let rx, rx > 0 {
            let cornerY = ry ?? rx
            return CGPath(roundedRect: rect, cornerWidth: rx, cornerHeight: cornerY, transform: nil)
        }
        return CGPath(rect: rect, transform: nil)
    }

    private func polyPath(_ s: String, close: Bool) -> CGPath {
        let n = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { Double($0) }
        let p = CGMutablePath()
        var idx = 0
        while idx + 1 < n.count {
            let pt = CGPoint(x: n[idx], y: n[idx + 1])
            if idx == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            idx += 2
        }
        if close { p.closeSubpath() }
        return p
    }

    private func dbl(_ s: String?) -> CGFloat? { s.flatMap { Double($0) }.map { CGFloat($0) } }

    /// Parse an SVG `transform` attribute (matrix/translate/scale/rotate).
    static func parseTransform(_ s: String?) -> CGAffineTransform {
        guard let s, !s.isEmpty else { return .identity }
        var result = CGAffineTransform.identity
        var scanner = s[...]
        while let open = scanner.firstIndex(of: "(") {
            let fn = scanner[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " }).last.map(String.init) ?? ""
            guard let close = scanner[open...].firstIndex(of: ")") else { break }
            let argStr = scanner[scanner.index(after: open)..<close]
            let args = argStr.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            let t: CGAffineTransform
            switch fn {
            case "matrix" where args.count == 6:
                t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate":
                t = CGAffineTransform(translationX: args.count > 0 ? args[0] : 0, y: args.count > 1 ? args[1] : 0)
            case "scale":
                t = CGAffineTransform(scaleX: args.count > 0 ? args[0] : 1, y: args.count > 1 ? args[1] : (args.first ?? 1))
            case "rotate" where args.count >= 1:
                let rad = args[0] * .pi / 180
                if args.count == 3 {
                    t = CGAffineTransform(translationX: args[1], y: args[2])
                        .rotated(by: rad)
                        .translatedBy(x: -args[1], y: -args[2])
                } else {
                    t = CGAffineTransform(rotationAngle: rad)
                }
            default:
                t = .identity
            }
            // SVG applies left-to-right: later multiply on the right of accumulated.
            result = t.concatenating(result)
            scanner = scanner[scanner.index(after: close)...]
        }
        return result
    }
}

private extension CGPath {
    var isEmpty: Bool { self.boundingBoxOfPath.isNull || self.boundingBoxOfPath.isEmpty }
}

/// Internal test hook exposing the transform parser to unit tests.
enum SVGShapeTestHook {
    static func parseTransform(_ s: String?) -> CGAffineTransform {
        SVGParserDelegate.parseTransform(s)
    }
}
