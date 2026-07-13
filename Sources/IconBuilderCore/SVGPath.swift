import Foundation
import CoreGraphics

/// Parses an SVG path `d` attribute into a `CGPath`.
/// Supports M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z (absolute and relative).
/// Coordinates are kept in SVG space (top-left origin, Y-down).
enum SVGPathParser {
    static func path(fromData d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = TokenScanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCommand: Character = " "
        var lastControl: CGPoint? = nil   // for S/T smoothing

        func num() -> CGFloat? { scanner.nextNumber().map { CGFloat($0) } }

        while let cmd = scanner.nextCommand() {
            let isRel = cmd.isLowercase
            switch Character(cmd.lowercased()) {
            case "m":
                guard let x = num(), let y = num() else { break }
                var p = CGPoint(x: x, y: y)
                if isRel { p.x += current.x; p.y += current.y }
                path.move(to: p)
                current = p; subpathStart = p; lastControl = nil
                // Subsequent implicit pairs are treated as line-to.
                while let lx = num(), let ly = num() {
                    var q = CGPoint(x: lx, y: ly)
                    if isRel { q.x += current.x; q.y += current.y }
                    path.addLine(to: q); current = q
                }
                lastControl = nil
            case "l":
                while let x = num(), let y = num() {
                    var p = CGPoint(x: x, y: y)
                    if isRel { p.x += current.x; p.y += current.y }
                    path.addLine(to: p); current = p
                }
                lastControl = nil
            case "h":
                while let x = num() {
                    let nx = isRel ? current.x + x : x
                    let p = CGPoint(x: nx, y: current.y)
                    path.addLine(to: p); current = p
                }
                lastControl = nil
            case "v":
                while let y = num() {
                    let ny = isRel ? current.y + y : y
                    let p = CGPoint(x: current.x, y: ny)
                    path.addLine(to: p); current = p
                }
                lastControl = nil
            case "c":
                while let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(),
                      let x = num(), let y = num() {
                    var c1 = CGPoint(x: x1, y: y1), c2 = CGPoint(x: x2, y: y2), p = CGPoint(x: x, y: y)
                    if isRel {
                        c1.x += current.x; c1.y += current.y
                        c2.x += current.x; c2.y += current.y
                        p.x += current.x; p.y += current.y
                    }
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastControl = c2; current = p
                }
            case "s":
                while let x2 = num(), let y2 = num(), let x = num(), let y = num() {
                    var c2 = CGPoint(x: x2, y: y2), p = CGPoint(x: x, y: y)
                    if isRel { c2.x += current.x; c2.y += current.y; p.x += current.x; p.y += current.y }
                    let c1: CGPoint
                    if "cs".contains(lastCommand.lowercased()), let lc = lastControl {
                        c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                    } else { c1 = current }
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastControl = c2; current = p
                }
            case "q":
                while let x1 = num(), let y1 = num(), let x = num(), let y = num() {
                    var c = CGPoint(x: x1, y: y1), p = CGPoint(x: x, y: y)
                    if isRel { c.x += current.x; c.y += current.y; p.x += current.x; p.y += current.y }
                    path.addQuadCurve(to: p, control: c)
                    lastControl = c; current = p
                }
            case "t":
                while let x = num(), let y = num() {
                    var p = CGPoint(x: x, y: y)
                    if isRel { p.x += current.x; p.y += current.y }
                    let c: CGPoint
                    if "qt".contains(lastCommand.lowercased()), let lc = lastControl {
                        c = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                    } else { c = current }
                    path.addQuadCurve(to: p, control: c)
                    lastControl = c; current = p
                }
            case "a":
                while let rx = num(), let ry = num(), let rot = num(),
                      let laf = num(), let sf = num(), let x = num(), let y = num() {
                    var end = CGPoint(x: x, y: y)
                    if isRel { end.x += current.x; end.y += current.y }
                    addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                           xRotationDeg: rot, largeArc: laf != 0, sweep: sf != 0)
                    current = end
                }
                lastControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart; lastControl = nil
            default:
                break
            }
            lastCommand = cmd
        }
        return path
    }

    /// Endpoint-parameterization SVG arc → center parameterization, drawn as an arc.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx: CGFloat, ry: CGFloat, xRotationDeg: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        var rx = abs(rx), ry = abs(ry)
        let phi = xRotationDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s; lambda = 1 }
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let co = sign * sqrt(den == 0 ? 0 : num / den)
        let cxp = co * (rx * y1p / ry)
        let cyp = co * (-ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(max(-1, min(1, dot / (len == 0 ? 1 : len))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        // Flatten the arc into cubic segments in the ellipse's local frame.
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + delta), sin2 = sin(theta + delta)
            func point(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + cosP * (rx * c) - sinP * (ry * s),
                        y: cy + sinP * (rx * c) + cosP * (ry * s))
            }
            let e1 = point(cos1, sin1)
            let e2 = point(cos2, sin2)
            let d1 = CGPoint(x: -rx * sin1, y: ry * cos1)
            let d2 = CGPoint(x: -rx * sin2, y: ry * cos2)
            let c1 = CGPoint(x: e1.x + t * (cosP * d1.x - sinP * d1.y),
                             y: e1.y + t * (sinP * d1.x + cosP * d1.y))
            let c2 = CGPoint(x: e2.x - t * (cosP * d2.x - sinP * d2.y),
                             y: e2.y - t * (sinP * d2.x + cosP * d2.y))
            path.addCurve(to: e2, control1: c1, control2: c2)
            theta += delta
        }
    }
}

/// Minimal scanner for SVG path token streams (commands + numbers).
private struct TokenScanner {
    private let chars: [Character]
    private var i = 0
    init(_ s: String) { chars = Array(s) }

    mutating func nextCommand() -> Character? {
        skipSeparators()
        guard i < chars.count else { return nil }
        let c = chars[i]
        if c.isLetter {
            i += 1
            return c
        }
        return nil
    }

    mutating func nextNumber() -> Double? {
        skipSeparators()
        // Peek: a number starts with digit, sign, or dot. If a letter is next, stop.
        guard i < chars.count else { return nil }
        if chars[i].isLetter { return nil }
        var s = ""
        if chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
        var seenDot = false, seenExp = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { s.append(c); i += 1 }
            else if c == "." && !seenDot && !seenExp { seenDot = true; s.append(c); i += 1 }
            else if (c == "e" || c == "E") && !seenExp {
                seenExp = true; s.append(c); i += 1
                if i < chars.count && (chars[i] == "+" || chars[i] == "-") { s.append(chars[i]); i += 1 }
            } else { break }
        }
        return Double(s)
    }

    private mutating func skipSeparators() {
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 } else { break }
        }
    }
}
