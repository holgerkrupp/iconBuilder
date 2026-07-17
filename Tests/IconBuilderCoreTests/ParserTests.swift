import XCTest
import CoreGraphics
@testable import IconBuilderCore

final class ParserTests: XCTestCase {
    func testColorSpecParsing() {
        let c = ColorSpec(string: "srgb:0.0,0.5,1.0,1.0")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.space, .srgb)
        XCTAssertEqual(c?.b, 1.0)
        let p3 = ColorSpec(string: "display-p3:0.27,0.60,0.84,1.0")
        XCTAssertEqual(p3?.space, .displayP3)
    }

    func testCMYKConversionBlack() {
        let cmyk = ColorConvert.cmyk(ColorSpec(space: .srgb, r: 0, g: 0, b: 0, a: 1))
        XCTAssertEqual(cmyk.k, 1, accuracy: 0.0001)
    }

    func testCMYKConversionPureRed() {
        let cmyk = ColorConvert.cmyk(ColorSpec(space: .srgb, r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(cmyk.k, 0, accuracy: 0.0001)
        XCTAssertEqual(cmyk.m, 1, accuracy: 0.0001)
        XCTAssertEqual(cmyk.y, 1, accuracy: 0.0001)
    }

    func testSVGPathParsesTriangle() {
        let d = "M0,0 L100,0 L50,100 Z"
        let path = SVGPathParser.path(fromData: d)
        XCTAssertFalse(path.boundingBoxOfPath.isNull)
        XCTAssertEqual(path.boundingBoxOfPath.width, 100, accuracy: 0.5)
    }

    func testSVGShapeParsesRect() {
        let svg = """
        <svg viewBox="0 0 1024 1024"><rect x="10" y="20" width="100" height="50"/></svg>
        """
        let shape = SVGShape.parse(data: Data(svg.utf8))
        XCTAssertNotNil(shape)
        XCTAssertEqual(shape?.viewBox.width, 1024)
    }

    /// Regression test for the Icon Composer coordinate model, calibrated
    /// against Icon Composer 2.0 reference exports: center origin, Y-down,
    /// p' = (p − 512)·scale + translation, applied per layer then per group,
    /// with groups/layers listed topmost-first.
    func testCoordinateModelMatchesIconComposer() throws {
        let manifestJSON = """
        {
          "fill": "automatic",
          "groups": [
            {
              "layers": [
                {
                  "image-name": "bar.svg",
                  "name": "bar",
                  "fill": { "solid": "srgb:1.0,0.0,0.0,1.0" },
                  "position": { "scale": 1.05, "translation-in-points": [-387.4, 383.5] }
                }
              ],
              "position": { "scale": 1.02, "translation-in-points": [393.8, 514.0] }
            }
          ]
        }
        """
        let barSVG = """
        <svg viewBox="0 0 1024 1024"><rect x="2.3" y="0" width="1020.9" height="171.5"/></svg>
        """
        let manifest = try JSONDecoder().decode(IconManifest.self, from: Data(manifestJSON.utf8))
        let shape = try XCTUnwrap(SVGShape.parse(data: Data(barSVG.utf8)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/x.icon"),
                               manifest: manifest, shapes: ["bar.svg": shape])
        var opts = RenderOptions(appearance: .light, recipe: .iOS26)
        opts.effects = false; opts.background = false; opts.clipToMask = false
        let img = try XCTUnwrap(Exporters.rasterize(doc, pixelSize: 1024, options: opts))

        // Expected bar top edge: ((0−512)·1.05 + 383.5)·1.02 + 514 + 512 ≈ 868.8
        // (matches the measured bottom-stripe seam at y≈865–869 in the
        // Icon Composer reference export).
        let data = try XCTUnwrap(img.dataProvider?.data) as Data
        let bpr = img.bytesPerRow
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * bpr + x * 4 + 3] }
        XCTAssertEqual(alpha(512, 850), 0, "above the bar top edge should be empty")
        XCTAssertGreaterThan(alpha(512, 890), 200, "below the bar top edge should be filled")
    }

    /// The print-ready export must produce a page of target+bleed size with a
    /// TrimBox on the finished size and a magenta die-cut stroke.
    func testPrintReadyPDFStructure() throws {
        let manifestJSON = """
        { "fill": "automatic", "groups": [ { "layers": [ {
            "image-name": "bar.svg", "name": "bar",
            "fill": { "solid": "srgb:1.0,0.0,0.0,1.0" },
            "position": { "scale": 1.0, "translation-in-points": [0, 0] }
        } ] } ] }
        """
        let barSVG = "<svg viewBox=\"0 0 1024 1024\"><rect x=\"0\" y=\"0\" width=\"1024\" height=\"1024\"/></svg>"
        let manifest = try JSONDecoder().decode(IconManifest.self, from: Data(manifestJSON.utf8))
        let shape = try XCTUnwrap(SVGShape.parse(data: Data(barSVG.utf8)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/x.icon"),
                               manifest: manifest, shapes: ["bar.svg": shape])

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("printtest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var opts = RenderOptions(appearance: .light, recipe: .iOS26, cmyk: true)
        opts.effects = false
        let p = Exporters.PrintOptions(targetSizeMM: 50, bleedMM: 3)
        try Exporters.exportPrintPDF(doc, to: url, print: p, options: opts)

        // Die line structure: /Separation spot color named CutContour, carried
        // in an optional-content layer of the same name.
        let rawBytes = try Data(contentsOf: url)
        let raw = String(decoding: rawBytes, as: UTF8.self)
        XCTAssertTrue(raw.contains("/Separation /CutContour /DeviceCMYK"),
                      "CutContour spot colorspace missing")
        XCTAssertTrue(raw.contains("/Type /OCG /Name (CutContour)"),
                      "CutContour layer (OCG) missing")
        XCTAssertTrue(raw.contains("/OCProperties"), "layer registration missing")

        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 1)
        let page = try XCTUnwrap(pdf.page(at: 1))

        // Page: (50 + 2·3) mm = 158.74 pt; TrimBox inset by the 8.5 pt bleed.
        let media = page.getBoxRect(.mediaBox)
        let trim = page.getBoxRect(.trimBox)
        XCTAssertEqual(media.width, 158.74, accuracy: 0.05)
        XCTAssertEqual(trim.minX, 8.504, accuracy: 0.05)
        XCTAssertEqual(trim.width, 141.73, accuracy: 0.05)

        // Rasterize at 4× and check actual ink:
        let scale: CGFloat = 4
        let px = Int(media.width * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: px, height: px,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        let img = try XCTUnwrap(ctx.makeImage())
        let data = try XCTUnwrap(img.dataProvider?.data) as Data
        let bpr = img.bytesPerRow
        func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (px - 1 - y) * bpr + x * 4   // flip to bottom-up PDF coords
            return (data[o], data[o + 1], data[o + 2])
        }

        // 1. Artwork center is the red icon fill.
        let center = rgb(px / 2, px / 2)
        XCTAssertGreaterThan(center.0, 150, "icon fill missing at center")
        XCTAssertLessThan(center.1, 120, "icon fill should be red")

        // 2. Bleed zone (left of the trim box, mid-height) carries artwork.
        let bleedPx = rgb(Int(4.0 * scale), px / 2)
        XCTAssertGreaterThan(bleedPx.0, 150, "bleed underlay missing")
        XCTAssertLessThan(bleedPx.1, 120, "bleed underlay should be red")

        // 3. Magenta die line crosses the trim edge at mid-height: scan a small
        //    window around x = trim.minX for a pixel with high R+B, low G.
        var foundMagenta = false
        let xc = Int(trim.minX * scale)
        for dx in -6...6 {
            let (r, g, b) = rgb(xc + dx, px / 2)
            // Magenta over the artwork: strong red, suppressed green, and a
            // clear blue lift relative to green.
            if r > 140 && g < 100 && b > g + 40 {
                foundMagenta = true; break
            }
        }
        XCTAssertTrue(foundMagenta, "magenta cut line not found at trim edge")
    }

    /// Quartz PDF gradients discard per-stop alpha. The PDF compatibility path
    /// must keep backdrop colors visible through a glass layer.
    func testPDFGlassRetainsBackdropTransparency() throws {
        let manifestJSON = """
        {
          "fill": { "solid": "srgb:1.0,0.0,0.0,1.0" },
          "groups": [
            {
              "translucency": { "enabled": true, "value": 0.5 },
              "specular": false,
              "layers": [ {
                "image-name": "glass.svg", "name": "glass", "glass": true,
                "opacity": 0.9,
                "fill": { "automatic-gradient": "srgb:0.0,1.0,1.0,1.0" }
              } ]
            },
            {
              "layers": [ {
                "image-name": "half.svg", "name": "half", "glass": false,
                "fill": { "solid": "srgb:0.0,0.0,1.0,1.0" }
              } ]
            }
          ]
        }
        """
        let fullSVG = "<svg viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\"/></svg>"
        let halfSVG = "<svg viewBox=\"0 0 1024 1024\"><rect x=\"512\" width=\"512\" height=\"1024\"/></svg>"
        let manifest = try JSONDecoder().decode(IconManifest.self, from: Data(manifestJSON.utf8))
        let glass = try XCTUnwrap(SVGShape.parse(data: Data(fullSVG.utf8)))
        let half = try XCTUnwrap(SVGShape.parse(data: Data(halfSVG.utf8)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/glass.icon"),
                               manifest: manifest,
                               shapes: ["glass.svg": glass, "half.svg": half])

        var options = RenderOptions(appearance: .light, recipe: .iOS27)
        options.effects = false
        options.clipToMask = false
        let pdfData = try XCTUnwrap(Exporters.pdfData(doc, pointSize: 100, options: options))
        let provider = try XCTUnwrap(CGDataProvider(data: pdfData as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(pdf.page(at: 1))

        let size = 400
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 4, y: 4)
        ctx.drawPDFPage(page)
        let image = try XCTUnwrap(ctx.makeImage())
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let row = image.bytesPerRow
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * row + x * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        let overRed = pixel(100, 200)
        let overBlue = pixel(300, 200)
        XCTAssertGreaterThan(overRed.0, overBlue.0 + 20,
                             "glass PDF fill became opaque and hid the backdrop")
        XCTAssertGreaterThan(overBlue.2, overRed.2 + 10,
                             "glass PDF fill did not transmit the blue backdrop")
    }

    /// ICC profile loading and profile-based CMYK conversion, using the
    /// system Generic CMYK profile (always present on macOS).
    func testPrintProfileConversion() throws {
        let url = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let profile = try PrintProfile.load(url: url)
        XCTAssertEqual(profile.space.model, .cmyk)
        XCTAssertFalse(profile.name.isEmpty)

        // A saturated red must convert to a magenta+yellow-dominant separation.
        let red = ColorSpec(space: .srgb, r: 0.86, g: 0.27, b: 0.25, a: 1)
        let converted = ColorConvert.cgColor(red, cmyk: true, profile: profile)
        let comps = try XCTUnwrap(converted.components)
        XCTAssertEqual(converted.numberOfComponents, 5) // CMYK + alpha
        XCTAssertGreaterThan(comps[1], 0.5, "magenta should dominate")
        XCTAssertGreaterThan(comps[2], 0.5, "yellow should dominate")
        XCTAssertLessThan(comps[0], 0.4, "little cyan in a red")

        // A non-CMYK profile must be rejected.
        let rgbURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")
        if FileManager.default.fileExists(atPath: rgbURL.path) {
            XCTAssertThrowsError(try PrintProfile.load(url: rgbURL))
        }
    }

    func testMatrixTransformApplied() {
        // translate(10,20) should move a unit rect's origin.
        let t = "translate(10,20)"
        let m = SVGShapeTestHook.parseTransform(t)
        let p = CGPoint(x: 0, y: 0).applying(m)
        XCTAssertEqual(p.x, 10, accuracy: 0.001)
        XCTAssertEqual(p.y, 20, accuracy: 0.001)
    }
}
