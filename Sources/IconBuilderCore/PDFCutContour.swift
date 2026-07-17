import Foundation
import CoreGraphics

/// Injects a die-cut contour into a Core Graphics-generated PDF as the
/// commercial-print standard structure:
///
///  - a `/Separation /CutContour` **spot color** (tint transform → 100%
///    magenta alternate, the convention print RIPs key on),
///  - stroked in its own **PDF layer** (Optional Content Group) named
///    `CutContour`, so prepress tools show and toggle it separately.
///
/// Core Graphics cannot author Separation color spaces, so this appends a
/// standard PDF *incremental update* to the finished file: new objects, an
/// updated page and catalog, and a new xref section. Works on CG output,
/// which uses classic cross-reference tables.
enum PDFCutContour {

    /// Returns the PDF with the contour added, or nil if the file's structure
    /// was not recognized (callers should fall back to the plain PDF).
    static func inject(into pdf: Data, contour: CGPath, lineWidth: CGFloat,
                       spotName: String = "CutContour") -> Data? {
        guard let src = String(data: pdf, encoding: .isoLatin1) else { return nil }

        // --- Locate the structural pieces of the CG-generated file. ---
        guard let sizeMatch = match(src, #"trailer\s*<<[^>]*?/Size (\d+)"#, group: 1),
              let size = Int(sizeMatch) else { return nil }
        guard let startxref = match(src, #"startxref\s+(\d+)"#, group: 1, last: true) else { return nil }
        guard let pageNumStr = match(src, #"(\d+) 0 obj\s*<<[^>]*?/Type /Page[^s]"#, group: 1) else { return nil }
        guard let catalogNumStr = match(src, #"(\d+) 0 obj\s*<<[^>]*?/Type /Catalog"#, group: 1) else { return nil }
        guard let pageNum = Int(pageNumStr), let catalogNum = Int(catalogNumStr) else { return nil }
        guard let trailerDict = match(src, #"trailer\s*<<(.*?)>>\s*startxref"#, group: 1, dotAll: true) else { return nil }

        guard let pageObj = objectSource(src, number: pageNum) else { return nil }
        guard let catalogObj = objectSource(src, number: catalogNum) else { return nil }

        // New object numbers.
        let fnNum = size          // tint transform function
        let csNum = size + 1      // separation colorspace
        let ocgNum = size + 2     // optional content group ("layer")
        let streamNum = size + 3  // cut-line content stream

        // --- Updated page object: extra content stream + resources. ---
        var newPage = pageObj.body
        // /Contents X 0 R → /Contents [ X 0 R  stream 0 R ]
        guard let contentsRef = match(newPage, #"/Contents (\d+ 0 R)"#, group: 1) else { return nil }
        newPage = newPage.replacingOccurrences(
            of: "/Contents \(contentsRef)",
            with: "/Contents [ \(contentsRef) \(streamNum) 0 R ]")

        // Resources may live inline in the page dict or in a separate object
        // (CG writes the latter). Register the colorspace + OCG property in
        // whichever dict actually holds the resources.
        func amendResources(_ dict: String) -> String? {
            var d = dict
            if d.contains("/ColorSpace <<") {
                d = d.replacingOccurrences(
                    of: "/ColorSpace <<",
                    with: "/ColorSpace << /CutCS \(csNum) 0 R")
            } else if let open = d.range(of: "<<") {
                d.replaceSubrange(open, with: "<< /ColorSpace << /CutCS \(csNum) 0 R >>")
            } else {
                return nil
            }
            guard let open = d.range(of: "<<") else { return nil }
            d.replaceSubrange(open, with: "<< /Properties << /ocCut \(ocgNum) 0 R >>")
            return d
        }

        var updatedResourcesObject: (number: Int, body: String)?
        if let resNumStr = match(newPage, #"/Resources (\d+) 0 R"#, group: 1),
           let resNum = Int(resNumStr) {
            // Indirect resources: rewrite that object in the update.
            guard let resObj = objectSource(src, number: resNum),
                  let amended = amendResources(resObj.body) else { return nil }
            updatedResourcesObject = (resNum, amended)
        } else if let resRange = inlineDictRange(of: "/Resources", in: newPage) {
            guard let amended = amendResources(String(newPage[resRange])) else { return nil }
            newPage.replaceSubrange(resRange, with: amended)
        } else {
            return nil
        }

        // --- Updated catalog: declare the layer. ---
        var newCatalog = catalogObj.body
        guard !newCatalog.contains("/OCProperties") else { return nil }
        guard let catalogOpen = newCatalog.range(of: "<<") else { return nil }
        newCatalog.replaceSubrange(catalogOpen, with:
            "<< /OCProperties << /OCGs [ \(ocgNum) 0 R ] /D << /Order [ \(ocgNum) 0 R ] /ON [ \(ocgNum) 0 R ] /BaseState /ON >> >>")

        // --- New objects. ---
        let fnObj = """
        \(fnNum) 0 obj
        << /FunctionType 2 /Domain [ 0 1 ] /C0 [ 0 0 0 0 ] /C1 [ 0 1 0 0 ] /N 1 >>
        endobj
        """
        let csObj = """
        \(csNum) 0 obj
        [ /Separation /\(pdfName(spotName)) /DeviceCMYK \(fnNum) 0 R ]
        endobj
        """
        let ocgObj = """
        \(ocgNum) 0 obj
        << /Type /OCG /Name (\(spotName)) >>
        endobj
        """
        let ops = pathOperators(contour)
        let streamBody = """
        /OC /ocCut BDC
        q
        \(fmt(lineWidth)) w
        /CutCS CS
        1 SCN
        \(ops)
        S
        Q
        EMC
        """
        let streamObj = """
        \(streamNum) 0 obj
        << /Length \(streamBody.lengthOfBytes(using: .isoLatin1)) >>
        stream
        \(streamBody)
        endstream
        endobj
        """

        // --- Assemble the incremental update. ---
        var appendix = "\n"
        var offsets: [Int: Int] = [:]   // object number → byte offset in final file
        func append(_ objectNumber: Int, _ text: String) {
            offsets[objectNumber] = pdf.count + appendix.lengthOfBytes(using: .isoLatin1)
            appendix += text + "\n"
        }
        append(pageNum, "\(pageNum) 0 obj\n\(newPage)\nendobj")
        append(catalogNum, "\(catalogNum) 0 obj\n\(newCatalog)\nendobj")
        if let res = updatedResourcesObject {
            append(res.number, "\(res.number) 0 obj\n\(res.body)\nendobj")
        }
        append(fnNum, fnObj)
        append(csNum, csObj)
        append(ocgNum, ocgObj)
        append(streamNum, streamObj)

        // Classic xref section: one subsection per contiguous run.
        let xrefOffset = pdf.count + appendix.lengthOfBytes(using: .isoLatin1)
        appendix += "xref\n"
        for run in contiguousRuns(offsets.keys.sorted()) {
            appendix += "\(run.first!) \(run.count)\n"
            for n in run {
                appendix += String(format: "%010d %05d n \n", offsets[n]!, 0)
            }
        }
        // Trailer: original dict with /Size bumped and /Prev added.
        var newTrailer = trailerDict.replacingOccurrences(
            of: "/Size \(size)", with: "/Size \(size + 4)")
        newTrailer += " /Prev \(startxref) "
        appendix += "trailer\n<<\(newTrailer)>>\nstartxref\n\(xrefOffset)\n%%EOF\n"

        var out = pdf
        out.append(Data(appendix.utf8))
        return out
    }

    // MARK: - Helpers

    /// Emit PDF path-construction operators for a CGPath (m/l/c/h).
    private static func pathOperators(_ path: CGPath) -> String {
        var ops: [String] = []
        path.applyWithBlock { elem in
            let e = elem.pointee
            switch e.type {
            case .moveToPoint:
                ops.append("\(pt(e.points[0])) m")
            case .addLineToPoint:
                ops.append("\(pt(e.points[0])) l")
            case .addQuadCurveToPoint:
                // PDF has no quad operator; elevate to cubic on emission.
                ops.append("\(pt(e.points[0])) \(pt(e.points[0])) \(pt(e.points[1])) c")
            case .addCurveToPoint:
                ops.append("\(pt(e.points[0])) \(pt(e.points[1])) \(pt(e.points[2])) c")
            case .closeSubpath:
                ops.append("h")
            @unknown default:
                break
            }
        }
        return ops.joined(separator: "\n")
    }

    private static func pt(_ p: CGPoint) -> String { "\(fmt(p.x)) \(fmt(p.y))" }

    private static func fmt(_ v: CGFloat) -> String {
        String(format: "%.4f", v)
    }

    /// Escape a spot name for use as a PDF name object.
    private static func pdfName(_ s: String) -> String {
        s.unicodeScalars.map { u in
            let c = Character(u)
            if c.isLetter || c.isNumber { return String(c) }
            return String(format: "#%02X", u.value)
        }.joined()
    }

    /// Range of the balanced `<< … >>` dictionary that directly follows `key`.
    private static func inlineDictRange(of key: String, in s: String) -> Range<String.Index>? {
        guard let keyRange = s.range(of: key + " <<") else { return nil }
        let start = s.index(keyRange.upperBound, offsetBy: -2)  // at the "<<"
        var depth = 0
        var i = start
        while i < s.endIndex {
            if s[i...].hasPrefix("<<") {
                depth += 1
                i = s.index(i, offsetBy: 2)
            } else if s[i...].hasPrefix(">>") {
                depth -= 1
                i = s.index(i, offsetBy: 2)
                if depth == 0 { return start..<i }
            } else {
                i = s.index(after: i)
            }
        }
        return nil
    }

    private static func contiguousRuns(_ sorted: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for n in sorted {
            if var last = runs.last, let tail = last.last, tail + 1 == n {
                last.append(n)
                runs[runs.count - 1] = last
            } else {
                runs.append([n])
            }
        }
        return runs
    }

    /// First (or last) regex capture in `s`.
    private static func match(_ s: String, _ pattern: String, group: Int,
                              last: Bool = false, dotAll: Bool = false) -> String? {
        let options: NSRegularExpression.Options = dotAll ? [.dotMatchesLineSeparators] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        let matches = re.matches(in: s, range: range)
        guard let m = last ? matches.last : matches.first,
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }

    /// The body (dict source between "N 0 obj" and "endobj") of object N.
    private static func objectSource(_ s: String, number: Int) -> (body: String, range: Range<String.Index>)? {
        guard let re = try? NSRegularExpression(
            pattern: "(?m)^\(number) 0 obj\\s*(.*?)\\s*endobj",
            options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range),
              let bodyRange = Range(m.range(at: 1), in: s) else { return nil }
        return (String(s[bodyRange]), bodyRange)
    }
}
